require "test-unit"
require "test/unit"
require_relative "../app/core"
include GSBCore
require 'yaml'
require 'tmpdir'
require 'fileutils'

ENV['TESTING_GSB'] = 'true'


Test::Unit.at_start do
    ENV['TESTING_GSB'] = 'true'
end

Test::Unit.at_exit do
end


class TestNewBridge < Test::Unit::TestCase

    $config = YAML.load_file("#{APP_ROOT}/etc/config.yml")


    def setup
        @tmpdir = Dir.mktmpdir
        @svnrepo = "file://#{@tmpdir}/svn-repo"
        @gitrepo = "file://#{@tmpdir}/testrepo.git"
        @ext_svn_wc = "#{@tmpdir}/ext_svn_wc"
        @ext_git_wc = "#{@tmpdir}/ext_git_wc"
        Dir.chdir @tmpdir do
            `svnadmin create svn-repo`
            `svn co #{@svnrepo} ext_svn_wc`
            `git init --bare testrepo.git`
            `git clone #{@gitrepo} ext_git_wc`
        end

    end

    def teardown
        FileUtils.rm_rf @tmpdir
    end

    def cleanup
        # puts "\nin cleanup"
    end

    def test_sanity_checks
        assert_nothing_raised do
            GSBCore.bridge_sanity_checks("https://github.com/Bioconductor/RGalaxy", 
                "https://hedgehog.fhcrc.org/bioconductor/trunk/madman/Rpacks/RGalaxy",
                "git-wins", $config['test_username'], $config['test_password'])
        end
    end

    def setup0
        Dir.chdir @ext_svn_wc do
            f = File.open("foo.txt", "w")
            f.write("i am foo")
            f.close
            `svn add foo.txt`
            `svn commit -m 'adding foo .txt'`
        end

    end

    def test_newbridge_0
        setup0

        assert_nothing_raised do
            GSBCore.new_bridge(@gitrepo, @svnrepo, "svn-wins",
                $config['test_username'], $config['test_username'])
        end
        tmpdir2 = Dir.mktmpdir
        Dir.chdir tmpdir2 do
            `git clone #{@gitrepo} clone`
            Dir.chdir "clone" do
                assert File.exists? "foo.txt"
            end
        end

    end

end

