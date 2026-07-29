#!/usr/bin/env ruby

require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

class NormalizeLoadCommandTest < Minitest::Test
  LOAD_PATH = "@executable_path/Dylibs/IPAPatchFramework"
  LC_LOAD_DYLIB = 0x0000000c
  LC_LOAD_UPWARD_DYLIB = 0x80000023

  def setup
    @normalizer = File.expand_path("normalize_load_command.rb", __dir__)
  end

  def thin_mach(command_type)
    command_size = ((24 + LOAD_PATH.bytesize + 1 + 7) / 8) * 8
    command = [
      command_type,
      command_size,
      24,
      0,
      0,
      0
    ].pack("V6")
    command << LOAD_PATH << "\0"
    command << ("\0" * (command_size - command.bytesize))

    header = [
      0xfeedfacf,
      0x0100000c,
      0,
      2,
      1,
      command_size,
      0,
      0
    ].pack("V8")
    header + command
  end

  def fat_mach(*slices)
    table_size = 8 + (20 * slices.length)
    next_offset = 0x1000
    entries = []

    slices.each_with_index do |slice, index|
      entries << [
        0x0100000c,
        index,
        next_offset,
        slice.bytesize,
        12
      ].pack("N5")
      next_offset += ((slice.bytesize + 0xfff) / 0x1000) * 0x1000
    end

    binary = [0xcafebabe, slices.length].pack("N2") + entries.join
    binary << ("\0" * (table_size - binary.bytesize))

    slices.each do |slice|
      aligned_offset = ((binary.bytesize + 0xfff) / 0x1000) * 0x1000
      binary << ("\0" * (aligned_offset - binary.bytesize))
      binary << slice
    end
    binary
  end

  def command_types(binary)
    offsets = []
    search_offset = 0
    while (path_offset = binary.index(LOAD_PATH, search_offset))
      offsets << binary.byteslice(path_offset - 24, 4).unpack1("V")
      search_offset = path_offset + 1
    end
    offsets
  end

  def normalize(binary)
    Dir.mktmpdir("ipapatch-normalizer-test") do |directory|
      path = File.join(directory, "AppBinary")
      File.binwrite(path, binary)
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        @normalizer,
        path,
        LOAD_PATH
      )
      return [File.binread(path), stdout, stderr, status]
    end
  end

  def test_normalizes_a_thin_mach_o
    result, stdout, stderr, status = normalize(thin_mach(LC_LOAD_UPWARD_DYLIB))

    assert status.success?, stderr
    assert_equal [LC_LOAD_DYLIB], command_types(result)
    assert_match "Normalized 1 load command", stdout
  end

  def test_normalizes_every_slice_in_a_fat_mach_o
    binary = fat_mach(
      thin_mach(LC_LOAD_UPWARD_DYLIB),
      thin_mach(LC_LOAD_UPWARD_DYLIB)
    )
    result, stdout, stderr, status = normalize(binary)

    assert status.success?, stderr
    assert_equal [LC_LOAD_DYLIB, LC_LOAD_DYLIB], command_types(result)
    assert_match "Normalized 2 load command", stdout
  end

  def test_accepts_commands_that_are_already_normalized
    result, stdout, stderr, status = normalize(thin_mach(LC_LOAD_DYLIB))

    assert status.success?, stderr
    assert_equal [LC_LOAD_DYLIB], command_types(result)
    assert_match "already use LC_LOAD_DYLIB", stdout
  end

  def test_fails_without_mutating_when_a_slice_has_no_matching_command
    binary = fat_mach(
      thin_mach(LC_LOAD_UPWARD_DYLIB),
      thin_mach(LC_LOAD_DYLIB).sub(LOAD_PATH, "@rpath/OtherLibrary".ljust(LOAD_PATH.bytesize, "_"))
    )
    result, _stdout, stderr, status = normalize(binary)

    refute status.success?
    assert_equal binary, result
    assert_match "slice 1, found 0", stderr
  end
end
