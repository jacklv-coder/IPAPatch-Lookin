#!/usr/bin/env ruby

# IPAPatch's bundled optool can write LC_LOAD_UPWARD_DYLIB even when invoked
# with "-c load" on newer macOS versions. Both commands use dylib_command and
# have the same binary layout, so normalize only the command type field.
#
# Parse the Mach-O headers instead of searching raw strings so every slice in a
# universal binary is validated and normalized independently.

LC_LOAD_DYLIB = 0x0000000c
LC_LOAD_UPWARD_DYLIB = 0x80000023

THIN_MAGICS = {
  "\xce\xfa\xed\xfe".b => [:little, 28],
  "\xcf\xfa\xed\xfe".b => [:little, 32],
  "\xfe\xed\xfa\xce".b => [:big, 28],
  "\xfe\xed\xfa\xcf".b => [:big, 32]
}.freeze

FAT_MAGICS = {
  "\xca\xfe\xba\xbe".b => [:big, 20, false],
  "\xca\xfe\xba\xbf".b => [:big, 32, true],
  "\xbe\xba\xfe\xca".b => [:little, 20, false],
  "\xbf\xba\xfe\xca".b => [:little, 32, true]
}.freeze

def read_uint32(data, offset, endian)
  bytes = data.byteslice(offset, 4)
  abort "truncated Mach-O at file offset #{offset}" unless bytes && bytes.bytesize == 4

  bytes.unpack1(endian == :little ? "V" : "N")
end

def read_uint64(data, offset, endian)
  bytes = data.byteslice(offset, 8)
  abort "truncated Mach-O at file offset #{offset}" unless bytes && bytes.bytesize == 8

  bytes.unpack1(endian == :little ? "Q<" : "Q>")
end

def mach_slices(data)
  magic = data.byteslice(0, 4)
  return [[0, data.bytesize]] if THIN_MAGICS.key?(magic)

  fat_format = FAT_MAGICS[magic]
  abort "unsupported Mach-O magic" unless fat_format

  endian, entry_size, uses_64_bit_offsets = fat_format
  slice_count = read_uint32(data, 4, endian)
  abort "universal Mach-O contains no slices" if slice_count == 0

  table_end = 8 + (slice_count * entry_size)
  abort "truncated universal Mach-O slice table" if table_end > data.bytesize

  slices = []
  slice_count.times do |index|
    entry_offset = 8 + (index * entry_size)
    if uses_64_bit_offsets
      slice_offset = read_uint64(data, entry_offset + 8, endian)
      slice_size = read_uint64(data, entry_offset + 16, endian)
    else
      slice_offset = read_uint32(data, entry_offset + 8, endian)
      slice_size = read_uint32(data, entry_offset + 12, endian)
    end

    if slice_size == 0 || slice_offset + slice_size > data.bytesize
      abort "invalid universal Mach-O slice #{index}"
    end
    slices << [slice_offset, slice_size]
  end
  slices
end

def matching_load_commands(data, slice_offset, slice_size, load_path)
  magic = data.byteslice(slice_offset, 4)
  format = THIN_MAGICS[magic]
  abort "unsupported Mach-O slice magic at file offset #{slice_offset}" unless format

  endian, header_size = format
  slice_end = slice_offset + slice_size
  command_count = read_uint32(data, slice_offset + 16, endian)
  commands_size = read_uint32(data, slice_offset + 20, endian)
  commands_offset = slice_offset + header_size
  commands_end = commands_offset + commands_size
  abort "invalid Mach-O load-command table" if commands_end > slice_end

  matches = []
  command_count.times do
    abort "truncated Mach-O load command" if commands_offset + 8 > commands_end

    command_type = read_uint32(data, commands_offset, endian)
    command_size = read_uint32(data, commands_offset + 4, endian)
    if command_size < 8 || commands_offset + command_size > commands_end
      abort "invalid Mach-O load command size"
    end

    if [LC_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB].include?(command_type)
      abort "truncated dylib load command" if command_size < 24

      name_offset = read_uint32(data, commands_offset + 8, endian)
      if name_offset >= 24 && name_offset < command_size
        name_start = commands_offset + name_offset
        name_bytes = data.byteslice(name_start, command_size - name_offset)
        name = name_bytes.split("\0", 2).first
        matches << [commands_offset, endian, command_type] if name == load_path
      end
    end

    commands_offset += command_size
  end

  abort "Mach-O load-command count exceeds its declared table" if commands_offset > commands_end
  matches
end

binary_path, load_path = ARGV
abort "usage: normalize_load_command.rb <Mach-O> <load-path>" unless binary_path && load_path

data = File.binread(binary_path)
slices = mach_slices(data)
commands_to_normalize = []

slices.each_with_index do |(slice_offset, slice_size), index|
  matches = matching_load_commands(data, slice_offset, slice_size, load_path)
  unless matches.length == 1
    abort "expected exactly one load command for #{load_path} in slice #{index}, found #{matches.length}"
  end
  commands_to_normalize.concat(matches)
end

changed_count = 0
File.open(binary_path, "r+b") do |file|
  commands_to_normalize.each do |command_offset, endian, command_type|
    next if command_type == LC_LOAD_DYLIB

    file.seek(command_offset)
    file.write([LC_LOAD_DYLIB].pack(endian == :little ? "V" : "N"))
    changed_count += 1
  end
end

if changed_count > 0
  puts "Normalized #{changed_count} load command(s) to LC_LOAD_DYLIB: #{load_path}"
else
  puts "All #{slices.length} slice(s) already use LC_LOAD_DYLIB: #{load_path}"
end
