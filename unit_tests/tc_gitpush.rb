ENV['TESTING_GSB'] = 'true'
require "test-unit"
require "test/unit"
require 'yaml'
require 'tmpdir'
require 'fileutils'
require 'pry'
require_relative "../app/core"
include GSBCore



Test::Unit.at_start do
    $config = YAML.load_file("#{APP_ROOT}/etc/config.yml")
    FileUtils.rm DB_FILE
    db = GSBCore.get_db
    GSBCore.login($config['test_username'], $config['test_password'])
end

Test::Unit.at_exit do
    #FileUtils.rm DB_FILE
end


class TestGitPush < Test::Unit::TestCase



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


    def setup0
        Dir.chdir @ext_svn_wc do
            f = File.open("foo.txt", "w")
            f.write("i am foo")
            f.close
            f = File.open("bar.txt", "w")
            f.write "i am bar"
            f.close
            `svn add foo.txt bar.txt`
            `svn commit -m 'adding foo.txt and bar.txt'`
        end
      
        GSBCore.new_bridge(@gitrepo, @svnrepo, "svn-wins",
            $config['test_username'], $config['test_username'],
            $config['test_email'])

        Dir.chdir @ext_git_wc do
            `git pull` # don't expect anything
            f = File.open("foo.txt", "a")
            f.write("\nanother line added to foo.txt")
            f.close
            `git add foo.txt`
            `git rm bar.txt`
            f = File.open("baz.txt", "w")
            f.write "i am baz"
            f.close
            `git add baz.txt`
            `git commit -m 'modification, addition, deletion'`
            `git push`
        end

        diff = GSBCore.get_diff @ext_git_wc, @ext_svn_wc



    end

    def test_handle_git_push_0
        setup0

        mock_push_object = {"repository" => {"url" => @gitrepo}}

        res = GSBCore.handle_git_push(mock_push_object)

        assert_equal "received", res


        Dir.chdir @ext_svn_wc do
            `svn up`
            assert(File.exists?("foo.txt"), "foo.txt doesn't exist!")
            assert(File.exists?("baz.txt"), "baz.txt doesn't exist!")

            assert( (!File.exists?("bar.txt")), "bar.txt exists but shouldn't!")

            assert(File.readlines("foo.txt").last == "another line added to foo.txt")

            log = `svn log -v`
            assert log =~ /modification, addition, deletion/
        end

    end

    def test_ping
        res = nil
        koan = "Chop water. Carry wood."
        assert_nothing_raised do
            res = GSBCore.handle_git_push({"zen" => koan})
        end
        assert_equal(koan + " Wow, that's pretty zen!", res)
    end

end


