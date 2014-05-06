ENV['TESTING_GSB'] = 'true'
require "test-unit"
require "test/unit"
require 'fileutils'
require 'tmpdir'
require 'pp'
require 'yaml'
require_relative "../app/core"
include GSBCore


Test::Unit.at_start do
    $config = YAML.load_file("#{APP_ROOT}/etc/config.yml")
end


class TestResolveDiffs < Test::Unit::TestCase


    def setup
        @tmpdir = Dir.mktmpdir
        # @dirA = "#{@tmpdir}/dirA"
        # @dirB = "#{@tmpdir}/dirB"
        # FileUtils.mkdir @dirA
        # FileUtils.mkdir @dirB
        @gitdir = "#{@tmpdir}/git"
        @svndir = "#{@tmpdir}/svn"
        FileUtils.mkdir @gitdir
        FileUtils.mkdir @svndir
        @svn_testrepo = "#{@svndir}/testrepo"
        @git_testrepo = "#{@gitdir}/testrepo"
        Dir.chdir @tmpdir do
            `svnadmin create svn-repo`
            `svn co file://#{@tmpdir}/svn-repo #{@svn_testrepo}`
            `git init --bare testrepo.git`
            `git clone file://#{@tmpdir}/testrepo.git #{@git_testrepo}`
        end
    end

    def teardown
        FileUtils.rm_rf @tmpdir
    end

    def cleanup
        # puts "\nin cleanup"
    end

    # tests

    def setup_repos_0
        # setup git
        Dir.chdir @git_testrepo do
            f = File.open("foo.txt", "w")
            f.puts "foo"
            f.close
            `git add foo.txt`
            `git commit -m 'my commit msg (git)'`
            `git push`
        end
        # setup svn
        Dir.chdir @svn_testrepo do
            f = File.open("foo.txt", "w")
            f.puts "bar"
            f.close
            `svn add foo.txt`
            `svn ci -m 'my commit msg (svn)'`
        end

    end

    def test_resolve_diff_0
        setup_repos_0
        Dir.chdir @tmpdir do
            diff = GSBCore.get_diff("git/testrepo", "svn/testrepo")
            GSBCore.resolve_diff(@git_testrepo, @svn_testrepo, diff, "svn")
            diff2 = GSBCore.get_diff("git/testrepo", "svn/testrepo")
            assert_nil(diff2)
        end
    end

    def setup_repos_1
        # setup git
        Dir.chdir @git_testrepo do
            Dir.mkdir "adir"
            `git add adir`
            `git commit -m 'my commit msg (git)'`
            `git push`
        end
    end

    def test_resolve_diff_1
        setup_repos_1
        Dir.chdir @tmpdir do
            diff = GSBCore.get_diff("git/testrepo", "svn/testrepo")
            expected = {:to_be_added=>["adir"], :to_be_deleted=>[], :to_be_copied=>[]}
            assert_equal(expected, diff)            
            GSBCore.resolve_diff(@git_testrepo, @svn_testrepo, diff, "svn")
            diff2 = GSBCore.get_diff("git/testrepo", "svn/testrepo")
            assert_nil(diff2)
        end
    end

    def setup_repos_2
        Dir.chdir @git_testrepo do
            f = File.open("foo.txt", "w")
            f.puts "foo"
            f.close
            FileUtils.mkdir "adir"
            FileUtils.touch "adir/afile"
            `git add foo.txt adir`
            `git commit -m 'a git commit msg'`
            `git push`
        end
        Dir.chdir @svn_testrepo do
            f = File.open("foo.txt", "w")
            f.puts "bar"
            f.close
            FileUtils.mkdir "bdir"
            `svn add foo.txt bdir`
            `svn commit -m 'an svn commit msg'`
        end
    end

    def test_resolve_diff_2
        setup_repos_2
        Dir.chdir @tmpdir do
            diff = GSBCore.get_diff("svn/testrepo", "git/testrepo")
            expected = {:to_be_added=>["bdir"], :to_be_deleted=>["adir"], :to_be_copied=>["foo.txt"]}
            assert_equal expected, diff
            GSBCore.resolve_diff(@svn_testrepo, @git_testrepo, diff, "git")
            diff2 = GSBCore.get_diff("svn/testrepo", "git/testrepo")
            assert_nil diff2
        end
    end

    def setup_repos_3
        Dir.chdir @git_testrepo do
            f = File.open(".gitignore", "w")
            f.puts "badpat*"
            f.close
            FileUtils.cp ".gitignore", @svn_testrepo
            `git add .gitignore`
            `git commit -m 'add .gitignore'`
            `git push`
        end
        Dir.chdir @svn_testrepo do
            f = File.open("badpat1", "w")
            f.write("stuff")
            f.close
            `svn add badpat1`
            `svn ci -m 'add badpat1'`
        end
    end

    def test_resolve_diff_3
        setup_repos_3
        Dir.chdir @tmpdir do
            diff = GSBCore.get_diff("svn/testrepo", "git/testrepo")
            expected = {:to_be_added=>["badpat1"], :to_be_deleted=>[], :to_be_copied=>[]}
            assert_equal expected, diff
            GSBCore.resolve_diff(@svn_testrepo, @git_testrepo, diff, "git")
            diff2 = GSBCore.get_diff(@svn_testrepo, @git_testrepo)
            assert_equal diff2, diff
        end
    end

    def setup_repos_4
        Dir.chdir @git_testrepo do
            `touch foo.class`
            `git add foo.class`
            `git commit -m 'adding foo.class'`
            `git push`
        end
        Dir.chdir @svn_testrepo do
            `svn propset svn:ignore -R *.class .`
        end
    end


    def test_resolve_diff_4 # test that svn ignores are honored
        setup_repos_4
        Dir.chdir @tmpdir do
            diff = GSBCore.get_diff("git/testrepo", "svn/testrepo")
            # expected = {:to_be_added=>["badpat1"], :to_be_deleted=>[], :to_be_copied=>[]}
            # assert_equal expected, diff
            GSBCore.resolve_diff(@git_testrepo, @svn_testrepo, diff, "svn")
            diff2 = GSBCore.get_diff(@svn_testrepo, @git_testrepo)
            # assert_equal diff2, diff
        end
    end

end

