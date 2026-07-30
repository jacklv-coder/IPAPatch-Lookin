#!/bin/sh

#  Copyright (c) 2017-present Wu Tian <wutian@me.com>.

#  Permission is hereby granted, free of charge, to any person obtaining a copy
#  of this software and associated documentation files (the "Software"), to deal
#  in the Software without restriction, including without limitation the rights
#  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#  copies of the Software, and to permit persons to whom the Software is
#  furnished to do so, subject to the following conditions:

#  The above copyright notice and this permission notice shall be included in
#  all copies or substantial portions of the Software.

#  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
#  THE SOFTWARE.

#  patch.sh
#  IPAPatch
#
#  Created by wutian on 2017/3/17.

PLATFORM="$1"

TEMP_PATH="${TARGET_TEMP_DIR:-${SRCROOT}/Temp}/IPAPatchWork"
OPTIONS_PATH="${SRCROOT}/Tools/options.plist"
ASSETS_PATH="${SRCROOT}/Assets"
LOCAL_CONFIGURATION_PATH="${SRCROOT}/.ipapatch-lookin.json"
LOCAL_CONFIGURATION_LOCK_PATH="${LOCAL_CONFIGURATION_PATH}.lock"

TARGET_IPA_PATH="${IPAPATCH_INPUT_IPA:-${ASSETS_PATH}/app.ipa}"
if [ "$PLATFORM" != "Mac" ]; then
    exec 9>"$LOCAL_CONFIGURATION_LOCK_PATH"
    if ! /usr/bin/lockf -s -t 30 9; then
        echo "error: Timed out waiting for the local IPA selection lock." >&2
        echo "Wait for the other ./ipapatch-lookin or Xcode build to finish, then try again." >&2
        exit 1
    fi

    TARGET_IPA_PATH="${IPAPATCH_INPUT_IPA:-}"
    if [ -z "$TARGET_IPA_PATH" ] && [ -f "$LOCAL_CONFIGURATION_PATH" ]; then
        TARGET_IPA_PATH=$(
            /usr/bin/plutil -extract inputIPAPath raw "$LOCAL_CONFIGURATION_PATH" 2>/dev/null \
                || true
        )
    fi
    TARGET_IPA_PATH="${TARGET_IPA_PATH:-${ASSETS_PATH}/app.ipa}"
fi
TARGET_MAC_APP_PATH="${ASSETS_PATH}/macapp.app"
FRAMEWORKS_TO_INJECT_PATH="${ASSETS_PATH}/Frameworks"
RESOURCES_TO_INJECT_PATH="${ASSETS_PATH}/Resources"
DYLIBS_TO_INJECT_PATH="${ASSETS_PATH}/Dylibs"
MACHO_NORMALIZER="${DERIVED_FILE_DIR:-${TEMP_PATH}}/ipapatch-macho-normalizer"
SWIFT_PLATFORM_DIRECTORY="${PLATFORM_NAME:-iphoneos}"

DUMMY_DISPLAY_NAME="" # To be found in Step 0
TARGET_BUNDLE_ID="" # To be found in Step 0
RESTORE_SYMBOLS=false
REMOVE_WATCHPLACEHOLDER=false
USE_ORIGINAL_ENTITLEMENTS=false
TEMP_APP_PATH=""   # To be found in Step 1
TARGET_APP_PATH="" # To be found in Step 3
TARGET_APP_CONTENTS_PATH="" # To be found in Step 3
TARGET_APP_FRAMEWORKS_PATH="" # To be found in Step 5

NormalizeLoadCommand () {
    binary_path=$1
    load_path=$2

    if ! "$MACHO_NORMALIZER" "$binary_path" "$load_path"; then
        echo "error: Failed to normalize Mach-O load command: $load_path" >&2
        exit 1
    fi
}

BuildMachONormalizer () {
    core_source="${SRCROOT}/Sources/IPAPatchLookinCore/MachOFile.swift"
    main_source="${SRCROOT}/Tools/MachONormalizerMain.swift"

    if [ ! -x "$MACHO_NORMALIZER" ] \
        || [ "$core_source" -nt "$MACHO_NORMALIZER" ] \
        || [ "$main_source" -nt "$MACHO_NORMALIZER" ]; then
        echo "Building Swift Mach-O normalizer"
        mkdir -p "$(dirname "$MACHO_NORMALIZER")"
        normalizer_sdk=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
        normalizer_arch=$(/usr/bin/uname -m)
        if ! /usr/bin/xcrun --sdk macosx swiftc \
            -O \
            -parse-as-library \
            -sdk "$normalizer_sdk" \
            -target "${normalizer_arch}-apple-macos13.0" \
            "$core_source" \
            "$main_source" \
            -o "$MACHO_NORMALIZER"; then
            echo "error: Failed to build the Swift Mach-O normalizer" >&2
            exit 1
        fi
    fi
}

# ---------------------------------------------------
# 0. Prepare Working Enviroment

rm -rf "$TEMP_PATH" || true
mkdir -p "$TEMP_PATH" || true

DUMMY_DISPLAY_NAME=$(/usr/libexec/PlistBuddy -c "Print CFBundleDisplayName"  "${SRCROOT}/$TARGET_NAME/Info.plist")
echo "DUMMY_DISPLAY_NAME: $DUMMY_DISPLAY_NAME"

RESTORE_SYMBOLS=$(/usr/libexec/PlistBuddy -c "Print RESTORE_SYMBOLS"  "${OPTIONS_PATH}")
IGNORE_UI_SUPPORTED_DEVICES=$(/usr/libexec/PlistBuddy -c "Print IGNORE_UI_SUPPORTED_DEVICES"  "${OPTIONS_PATH}")
REMOVE_WATCHPLACEHOLDER=$(/usr/libexec/PlistBuddy -c "Print REMOVE_WATCHPLACEHOLDER"  "${OPTIONS_PATH}")
USE_ORIGINAL_ENTITLEMENTS=$(/usr/libexec/PlistBuddy -c "Print USE_ORIGINAL_ENTITLEMENTS"  "${OPTIONS_PATH}")

echo "RESTORE_SYMBOLS: $RESTORE_SYMBOLS"
echo "CREATE_IPA_FILE: $CREATE_IPA_FILE"
echo "IGNORE_UI_SUPPORTED_DEVICES: $IGNORE_UI_SUPPORTED_DEVICES"

TARGET_BUNDLE_ID="$PRODUCT_BUNDLE_IDENTIFIER"
echo "TARGET_BUNDLE_ID: $TARGET_BUNDLE_ID"

if [ "$PLATFORM" != "Mac" ] && [ ! -s "$TARGET_IPA_PATH" ]; then
    echo "error: Missing decrypted IPA at $TARGET_IPA_PATH" >&2
    echo "Run ./ipapatch-lookin run /path/to/app.ipa to prepare this Xcode project." >&2
    exit 1
fi

BuildMachONormalizer


# ---------------------------------------------------
# 1. Extract Target IPA

if [ $PLATFORM = "Mac" ]
then
    echo "Copying Mac App to Temp folder"
    cp -rP "$TARGET_MAC_APP_PATH" "$TEMP_PATH"
    TEMP_APP_PATH=$(set -- "$TEMP_PATH/"*.app; echo "$1")
else
    echo "Extracting iOS App to Temp folder"
    unzip -oqq "$TARGET_IPA_PATH" -d "$TEMP_PATH"
    TEMP_APP_PATH=$(set -- "$TEMP_PATH/Payload/"*.app; echo "$1")
fi
    
echo "TEMP_APP_PATH: $TEMP_APP_PATH"

# ---------------------------------------------------
# 2 restore symbol and integrate to Mach-O File

if [ "$RESTORE_SYMBOLS" = true ]; then

    # ---------------------------------------------------
    # 2.1 try to thin Mach-O File

    MACH_O_FILE_NAME=`basename $TEMP_APP_PATH .app`
    MACH_O_FILE_PATH=$TEMP_APP_PATH/$MACH_O_FILE_NAME
    echo "MACH_O_FILE_PATH: $MACH_O_FILE_PATH"

    ARCHS=`lipo -archs $MACH_O_FILE_PATH`
    ARCH_COUNT=${#ARCHS[@]}
    
    if [ $ARCH_COUNT -eq 1 ]; then
        echo "skipping lipo -thin: non-fat binary"
    else
        lipo -thin armv7 $MACH_O_FILE_PATH -o $TEMP_PATH/"$MACH_O_FILE_NAME"_armv7
        lipo -thin arm64 $MACH_O_FILE_PATH -o $TEMP_PATH/"$MACH_O_FILE_NAME"_arm64
    fi

    # ---------------------------------------------------
    # 2.2 try to restore symbol by archs

    # Sources: https://github.com/tobefuturer/restore-symbol
    # restore symbol technique

    RESTORE_SYMBOL_TOOL="${SRCROOT}/Tools/restore-symbol"
    
    if [ $ARCH_COUNT -eq 1 ]; then
        "$RESTORE_SYMBOL_TOOL" $MACH_O_FILE_PATH -o $TEMP_PATH/$"$MACH_O_FILE_NAME"_with_symbol
    else
        "$RESTORE_SYMBOL_TOOL" $TEMP_PATH/$"$MACH_O_FILE_NAME"_armv7 -o $TEMP_PATH/$"$MACH_O_FILE_NAME"_armv7_with_symbol
        "$RESTORE_SYMBOL_TOOL" $TEMP_PATH/$"$MACH_O_FILE_NAME"_arm64 -o $TEMP_PATH/$"$MACH_O_FILE_NAME"_arm64_with_symbol
    fi

    # ---------------------------------------------------
    # 2.3 reintegrate Mach-O File

    if [ $ARCH_COUNT -eq 1 ]; then
        echo "skipping lipo -create: non-fat binary"
    else
        lipo -create $TEMP_PATH/"$MACH_O_FILE_NAME"_armv7_with_symbol $TEMP_PATH/"$MACH_O_FILE_NAME"_arm64_with_symbol -o $TEMP_PATH/"$MACH_O_FILE_NAME"_with_symbol
    fi

    rm -f $MACH_O_FILE_PATH
    cp $TEMP_PATH/"$MACH_O_FILE_NAME"_with_symbol $MACH_O_FILE_PATH

fi # [ "$RESTORE_SYMBOLS" ]


# ---------------------------------------------------
# 3. Overwrite DummyApp IPA with Target App Contents

TARGET_APP_PATH="$BUILT_PRODUCTS_DIR/$TARGET_NAME.app"
if [ $PLATFORM = "Mac" ]
then
    TARGET_APP_CONTENTS_PATH="$TARGET_APP_PATH/Contents"
else
    TARGET_APP_CONTENTS_PATH="$TARGET_APP_PATH"
fi
echo "TARGET_APP_PATH: $TARGET_APP_PATH"

# 3.1 Backup embedded.mobileprovision from DummyApp if it exists (generated by Xcode)
BACKUP_PROVISIONING_PROFILE=""
if [ $PLATFORM != "Mac" ] && [ -f "$TARGET_APP_PATH/embedded.mobileprovision" ]; then
    echo "Backing up embedded.mobileprovision from DummyApp"
    BACKUP_PROVISIONING_PROFILE="$TEMP_PATH/embedded.mobileprovision.backup"
    cp "$TARGET_APP_PATH/embedded.mobileprovision" "$BACKUP_PROVISIONING_PROFILE"
fi

rm -rf "$TARGET_APP_PATH" || true
mkdir -p "$TARGET_APP_PATH" || true
cp -rfP "$TEMP_APP_PATH/" "$TARGET_APP_PATH/"

# 3.2 Restore backed up embedded.mobileprovision
if [ -n "$BACKUP_PROVISIONING_PROFILE" ] && [ -f "$BACKUP_PROVISIONING_PROFILE" ]; then
    echo "Restoring embedded.mobileprovision from backup"
    cp "$BACKUP_PROVISIONING_PROFILE" "$TARGET_APP_PATH/embedded.mobileprovision"
fi




# ---------------------------------------------------
# 4. Inject the Executable We Wrote and Built (IPAPatchFramework.framework)

APP_BINARY=`plutil -convert xml1 -o - $TARGET_APP_CONTENTS_PATH/Info.plist|grep -A1 Exec|tail -n1|cut -f2 -d\>|cut -f1 -d\<`
if [ $PLATFORM = "Mac" ]
then
    APP_BINARY="MacOS/$APP_BINARY"
fi
OPTOOL="${SRCROOT}/Tools/optool"

mkdir -p "$TARGET_APP_CONTENTS_PATH/Dylibs"
if [ $PLATFORM = "Mac" ]
then
    cp "$BUILT_PRODUCTS_DIR/IPAPatchFrameworkMac.framework/IPAPatchFrameworkMac" "$TARGET_APP_CONTENTS_PATH/Dylibs/IPAPatchFramework"
else
    cp "$BUILT_PRODUCTS_DIR/IPAPatchFramework.framework/IPAPatchFramework" "$TARGET_APP_CONTENTS_PATH/Dylibs/IPAPatchFramework"
fi
for file in `ls -1 "$TARGET_APP_CONTENTS_PATH/Dylibs"`; do
    echo -n '     '
    
    if [ $PLATFORM = "Mac" ]
    then
        FRAMEWORK_LOAD_PATH="@executable_path/../Dylibs/$file"
    else
        FRAMEWORK_LOAD_PATH="@executable_path/Dylibs/$file"
    fi
    
    echo "Install Load: $file -> $FRAMEWORK_LOAD_PATH"
    "$OPTOOL" install -c load -p "$FRAMEWORK_LOAD_PATH" -t "$TARGET_APP_CONTENTS_PATH/$APP_BINARY"
    NormalizeLoadCommand "$TARGET_APP_CONTENTS_PATH/$APP_BINARY" "$FRAMEWORK_LOAD_PATH"
done

chmod +x "$TARGET_APP_CONTENTS_PATH/$APP_BINARY"




# ---------------------------------------------------
# 5. Inject External Files if Exists

CopySwiftStdLib () {
	source_file=$1
	target_dir=$2

	otool -L $source_file | while read -r line ; do
		if [[ $line = "@rpath/libswift"* ]]; then
			re="@rpath\/(libswift[^[:space:]]+.dylib)[[:space:]]";
			if [[ $line =~ $re ]]; then
				LIBNAME=${BASH_REMATCH[1]};
				if ! [ -e "$target_dir/$LIBNAME" ]; then
					LIB_SOURCE_PATH="${TOOLCHAIN_DIR}/usr/lib/swift/${SWIFT_PLATFORM_DIRECTORY}/${LIBNAME}"
					if [ -e $LIB_SOURCE_PATH ]; then
						echo "Copying $LIBNAME: $LIB_SOURCE_PATH"
						cp -rf "$LIB_SOURCE_PATH" "$target_dir"

						# resolve nested dependecies
						CopySwiftStdLib "$target_dir/$LIBNAME" "$target_dir"
					fi
				fi 
			fi
		fi
	done
}

# 5-1. Inject External Frameworks if Exists
TARGET_APP_FRAMEWORKS_PATH="$TARGET_APP_CONTENTS_PATH/Frameworks"

echo "Injecting Frameworks from $FRAMEWORKS_TO_INJECT_PATH"
for file in `ls -1 "${FRAMEWORKS_TO_INJECT_PATH}"`; do
    extension="${file##*.}"
    echo "$file 's extension is $extension"

    if [ "$extension" != "framework" ]
    then
        continue
    fi

    mkdir -p "$TARGET_APP_FRAMEWORKS_PATH"
    rsync -av --exclude=".*" "${FRAMEWORKS_TO_INJECT_PATH}/$file" "$TARGET_APP_FRAMEWORKS_PATH"
    filename="${file%.*}"

    echo -n '     '
    echo "Install Load: $file -> @executable_path/Frameworks/$file/$filename"

    "$OPTOOL" install -c load -p "@executable_path/Frameworks/$file/$filename" -t "$TARGET_APP_CONTENTS_PATH/$APP_BINARY"
    NormalizeLoadCommand "$TARGET_APP_CONTENTS_PATH/$APP_BINARY" "@executable_path/Frameworks/$file/$filename"

    CopySwiftStdLib "$TARGET_APP_FRAMEWORKS_PATH/$file/$filename" "$TARGET_APP_FRAMEWORKS_PATH"
done

# 5-2. Inject Dylibs if Exists
echo "Injecting Dylibs from $DYLIBS_TO_INJECT_PATH"
for file in `ls -1 "${DYLIBS_TO_INJECT_PATH}"`; do
    if [[ $file = "."* ]]; then
        continue
    fi

    filename="${file%.*}"
   	cp "$DYLIBS_TO_INJECT_PATH/$filename" "$TARGET_APP_CONTENTS_PATH/Dylibs/$filename"

    echo -n '     '
	echo "Install Load: $file -> @executable_path/Dylibs/$filename"

    "$OPTOOL" install -c load -p "@executable_path/Dylibs/$filename" -t "$TARGET_APP_CONTENTS_PATH/$APP_BINARY"
    NormalizeLoadCommand "$TARGET_APP_CONTENTS_PATH/$APP_BINARY" "@executable_path/Dylibs/$filename"

    CopySwiftStdLib "$TARGET_APP_CONTENTS_PATH/Dylibs/$filename" "$TARGET_APP_FRAMEWORKS_PATH"
done

# 5-3. Inject External Resources if Exists
echo "Injecting Resources from $RESOURCES_TO_INJECT_PATH"
rsync -av --exclude=".*" "${RESOURCES_TO_INJECT_PATH}/" "$TARGET_APP_CONTENTS_PATH"






# ---------------------------------------------------
# 6. Remove Embedded Extensions, To Simplify the Signing Process

echo "Removing AppExtensions"
rm -rf "$TARGET_APP_CONTENTS_PATH/PlugIns" || true
rm -rf "$TARGET_APP_CONTENTS_PATH/Extensions" || true
rm -rf "$TARGET_APP_CONTENTS_PATH/AppClips" || true
rm -rf "$TARGET_APP_CONTENTS_PATH/Watch" || true
find "$TARGET_APP_CONTENTS_PATH" -type d -name "*.appex" -prune -exec rm -rf {} +

echo "Removing App Store SC_Info metadata"
rm -rf "$TARGET_APP_CONTENTS_PATH/SC_Info" || true

if [ "$REMOVE_WATCHPLACEHOLDER" = true ]; then
    echo "Removing com.apple.WatchPlaceholder"
    rm -rf "$TARGET_APP_CONTENTS_PATH/com.apple.WatchPlaceholder" || true
fi


# ---------------------------------------------------
# 7. Update Info.plist for Target App

echo "Updating BundleID:$PRODUCT_BUNDLE_IDENTIFIER, DisplayName:$TARGET_DISPLAY_NAME"
TARGET_DISPLAY_NAME=$(/usr/libexec/PlistBuddy -c "Print CFBundleDisplayName"  "$TARGET_APP_CONTENTS_PATH/Info.plist")
TARGET_DISPLAY_NAME="$DUMMY_DISPLAY_NAME$TARGET_DISPLAY_NAME"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $PRODUCT_BUNDLE_IDENTIFIER" "$TARGET_APP_CONTENTS_PATH/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $TARGET_DISPLAY_NAME" "$TARGET_APP_CONTENTS_PATH/Info.plist"

if [ "$IGNORE_UI_SUPPORTED_DEVICES" = true ]; then
    /usr/libexec/PlistBuddy -c "Delete :UISupportedDevices" "$TARGET_APP_CONTENTS_PATH/Info.plist"
fi

# ---------------------------------------------------
# 8. Code Sign All The Things

if [ "$CODE_SIGNING_ALLOWED" = "NO" ] || [ -z "$EXPANDED_CODE_SIGN_IDENTITY" ]; then
    echo "Skipping code signing for local patch verification"
    echo "A signed device build still requires an Apple ID, development team, and provisioning profile in Xcode."
else

if [ "$USE_ORIGINAL_ENTITLEMENTS" = true ]; then
ENTITLEMENTS="$TEMP_PATH/entitlements.xcent"
codesign -d --entitlements :- "$TARGET_APP_PATH" > "$ENTITLEMENTS"
fi

# 8.1 Embed Provisioning Profile (Required for iOS device installation)
if [ $PLATFORM != "Mac" ] && [ "${EFFECTIVE_PLATFORM_NAME:-}" != "-iphonesimulator" ]; then
    echo "Embedding Provisioning Profile"
    
    # Try to find the provisioning profile from Xcode build settings
    if [ -n "$EXPANDED_PROVISIONING_PROFILE" ]; then
        PROFILE_PATH="$HOME/Library/MobileDevice/Provisioning Profiles/${EXPANDED_PROVISIONING_PROFILE}.mobileprovision"
        if [ -f "$PROFILE_PATH" ]; then
            echo "Using profile from EXPANDED_PROVISIONING_PROFILE: $PROFILE_PATH"
            cp "$PROFILE_PATH" "$TARGET_APP_CONTENTS_PATH/embedded.mobileprovision"
        fi
    fi
    
    # If not found, try to find a matching profile by bundle ID and team ID
    if [ ! -f "$TARGET_APP_CONTENTS_PATH/embedded.mobileprovision" ]; then
        echo "Searching for matching provisioning profile for bundle ID: $PRODUCT_BUNDLE_IDENTIFIER"
        PROFILES_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
        
        # Get team ID from code sign identity or build settings
        CURRENT_TEAM_ID="${DEVELOPMENT_TEAM}"
        if [ -z "$CURRENT_TEAM_ID" ] && [ -n "$EXPANDED_CODE_SIGN_IDENTITY_NAME" ]; then
            # Try to extract team ID from identity name (format: "Apple Development: Name (TEAMID)")
            CURRENT_TEAM_ID=$(echo "$EXPANDED_CODE_SIGN_IDENTITY_NAME" | grep -oE '\([A-Z0-9]+\)$' | tr -d '()')
        fi
        echo "Looking for profiles with Team ID: $CURRENT_TEAM_ID"
        
        BEST_MATCH_PROFILE=""
        WILDCARD_PROFILE=""
        
        for PROFILE in "$PROFILES_DIR"/*.mobileprovision; do
            if [ -f "$PROFILE" ]; then
                # Decode profile and extract info
                PROFILE_CONTENT=$(security cms -D -i "$PROFILE" 2>/dev/null)
                if [ -z "$PROFILE_CONTENT" ]; then
                    continue
                fi
                
                # Extract bundle ID pattern from profile
                PROFILE_APP_ID=$(echo "$PROFILE_CONTENT" | plutil -extract Entitlements.application-identifier raw - 2>/dev/null)
                PROFILE_TEAM_ID=$(echo "$PROFILE_CONTENT" | plutil -extract TeamIdentifier.0 raw - 2>/dev/null)
                
                # Remove team ID prefix from app ID to get bundle ID pattern
                PROFILE_BUNDLE_ID=$(echo "$PROFILE_APP_ID" | sed 's/^[A-Z0-9]*\.//')
                
                # Check team ID first
                if [ -n "$CURRENT_TEAM_ID" ] && [ "$PROFILE_TEAM_ID" != "$CURRENT_TEAM_ID" ]; then
                    continue
                fi
                
                # Check if profile matches (exact match or wildcard)
                if [ "$PROFILE_BUNDLE_ID" = "$PRODUCT_BUNDLE_IDENTIFIER" ]; then
                    # Exact match found
                    BEST_MATCH_PROFILE="$PROFILE"
                    break
                elif [ "$PROFILE_BUNDLE_ID" = "*" ]; then
                    # Wildcard profile - save as fallback
                    WILDCARD_PROFILE="$PROFILE"
                fi
            fi
        done
        
        # Use best match or fallback to wildcard
        SELECTED_PROFILE="${BEST_MATCH_PROFILE:-$WILDCARD_PROFILE}"
        if [ -n "$SELECTED_PROFILE" ]; then
            echo "Found matching profile: $SELECTED_PROFILE"
            cp "$SELECTED_PROFILE" "$TARGET_APP_CONTENTS_PATH/embedded.mobileprovision"
        fi
    fi
    
    if [ -f "$TARGET_APP_CONTENTS_PATH/embedded.mobileprovision" ]; then
        echo "Provisioning profile embedded successfully"
    else
        echo "WARNING: No matching provisioning profile found. Installation on device may fail."
        echo "Please ensure you have a valid provisioning profile for bundle ID: $PRODUCT_BUNDLE_IDENTIFIER"
    fi
fi

echo "Code Signing Dylibs"
if [ "$USE_ORIGINAL_ENTITLEMENTS" = true ]; then
    /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "$TARGET_APP_CONTENTS_PATH/Dylibs/"*
else
    /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$TARGET_APP_CONTENTS_PATH/Dylibs/"*
fi


echo "Code Signing Frameworks"
if [ -d "$TARGET_APP_FRAMEWORKS_PATH" ]; then
    if [ "$USE_ORIGINAL_ENTITLEMENTS" = true ]; then
        echo "/usr/bin/codesign --force --sign $EXPANDED_CODE_SIGN_IDENTITY --entitlements $ENTITLEMENTS $TARGET_APP_FRAMEWORKS_PATH/*"
        /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "$TARGET_APP_FRAMEWORKS_PATH/"*
    else
        echo "/usr/bin/codesign --force --sign $EXPANDED_CODE_SIGN_IDENTITY $TARGET_APP_FRAMEWORKS_PATH/*"
        /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$TARGET_APP_FRAMEWORKS_PATH/"*
    fi
fi

echo "Code Signing App Binary"
if [ "$USE_ORIGINAL_ENTITLEMENTS" = true ]; then
    /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none --entitlements "$ENTITLEMENTS" "$TARGET_APP_PATH"
    if [ $PLATFORM = "Mac" ]
    then
        /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none --entitlements "$ENTITLEMENTS" "$TARGET_APP_CONTENTS_PATH/MacOS/"*
    fi
else
    /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$TARGET_APP_PATH"
    if [ $PLATFORM = "Mac" ]
    then
        /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$TARGET_APP_CONTENTS_PATH/MacOS/"*
    fi
fi

fi





# ---------------------------------------------------
# 9. Install
#
#    Nothing To Do, Xcode Will Automatically Install the DummyApp We Overwrited
echo "Done"
