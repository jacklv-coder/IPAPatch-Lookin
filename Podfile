platform :ios, "15.0"

use_frameworks! :linkage => :static
inhibit_all_warnings!

project "IPAPatch.xcodeproj"

target "IPAPatchFramework" do
  pod "LookinServer/Core", "1.2.8", :configurations => ["Debug"]
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = "15.0"
    end
  end
end
