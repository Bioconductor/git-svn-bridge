require "test-unit"
require "test/unit"
require_relative "../app/core"
include GSBCore
require 'fileutils'
require 'tmpdir'
require 'pp'

ENV['TESTING_GSB'] = 'true'


Test::Unit.at_start do
    ENV['TESTING_GSB'] = 'true'
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
        @gitdir = "#{$tmpdir}/git"
        @svndir = "#{$tmpdir}/svn"
        FileUtils.mkdir @gitdir
        FileUtils.mkdir @svndir
        @git_testrepo = "#{@gitdir}/testrepo"
        @svn_testrepo = "#{@svndir}/testrepo"
        FileUtils.mkdir @git_testrepo
        FileUtils.mkdir @svn_testrepo
    end

    def teardown
        FileUtils.rm_rf @dirA
        FileUtils.rm_rf @dirB
        FileUtils.rm_rf @gitdir
        FileUtils.rm_rf @svndir
    end

    def cleanup
        # puts "\nin cleanup"
    end


    def test_diffnothing
        Dir.chdir $tmpdir do
            assert(GSBCore.get_diff(@dirA, @dirB).nil?)
        end
    end


    def test_diff2
        Dir.chdir $tmpdir do
            FileUtils.touch "#{@git_testrepo}/feet"
            FileUtils.touch "#{@svn_testrepo}/toes"
            diff = GSBCore.get_diff(@git_testrepo, @svn_testrepo)
            assert_not_nil(diff)
            expected = {:to_be_added=>["feet"], :to_be_deleted=>["toes"], :to_be_copied=>[]}
            assert_equal(expected, diff)
        end
    end

    def test_diff3
        Dir.chdir $tmpdir do
            f = File.open("#{@git_testrepo}/foo", "w")
            f.write "txt1"
            f.close
            f = File.open("#{@svn_testrepo}/foo", "w")
            f.write "txt2"
            f.close
            diff = GSBCore.get_diff(@git_testrepo, @svn_testrepo)
            expected = {:to_be_added=>[], :to_be_deleted=>[], :to_be_copied=>["foo"]}
            assert_equal(expected, diff)
        end
    end

end

