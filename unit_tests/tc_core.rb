require "test-unit"
require "test/unit"
require_relative "../app/core"
include GSBCore
require 'fileutils'
require 'tmpdir'



Test::Unit.at_start do
  puts "in at_start"
  $tmpdir = Dir.mktmpdir
  puts "$tmpdir = #{$tmpdir}"
end

Test::Unit.at_exit do
  puts "in at_exit"
  FileUtils.rm_rf $tmpdir
end


class TestCore < Test::Unit::TestCase




    def setup
        @dirA = "#{$tmpdir}/dirA"
        @dirB = "#{$tmpdir}/dirB"
        FileUtils.mkdir @dirA
        FileUtils.mkdir @dirB
    end

    def teardown
        FileUtils.rm_rf @dirA
        FileUtils.rm_rf @dirB
    end

    def cleanup
        # puts "\nin cleanup"
    end


    def test_diffnothing
        Dir.chdir $tmpdir do
            assert(GSBCore.get_diff(@dirA, @dirB).nil?)
        end

    end


end

