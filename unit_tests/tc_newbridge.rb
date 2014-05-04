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


class TestNewBridge < Test::Unit::TestCase



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
                $config['test_username'], $config['test_username'],
                $config['test_email'])
        end
        tmpdir2 = Dir.mktmpdir
        Dir.chdir tmpdir2 do
            `git clone #{@gitrepo} clone`
            Dir.chdir "clone" do
                assert File.exists? "foo.txt"
                assert File.readlines("foo.txt").first == "i am foo"
                log = `git log -n 1`
                assert log =~ /setting up git-svn bridge/
                assert log =~  /Author: #{$config['test_name']} <#{$config['test_email']}>/
            end
        end
    end


    def setup1
        Dir.chdir @ext_svn_wc do
            f = File.open("foo.txt", "w")
            f.write("i am foo")
            f.close
            `svn add foo.txt`
            `svn commit -m 'adding foo .txt'`
        end
        Dir.chdir @ext_git_wc do
            f = File.open("bar.txt", "w")
            f.write "i am bar"
            f.close
            `git add bar.txt`
            `git commit -m 'adding bar.txt'`
            `git push`
        end
    end

    def test_newbridge_1
        setup1

        assert_nothing_raised do
            GSBCore.new_bridge(@gitrepo, @svnrepo, "git-wins",
                $config['test_username'], $config['test_username'],
                $config['test_email'])
        end
        tmpdir2 = Dir.mktmpdir
        Dir.chdir tmpdir2 do
            `svn co #{@svnrepo} clone`
            Dir.chdir "clone" do
                assert File.exists? "bar.txt"
                assert File.readlines("bar.txt").first == "i am bar"
                assert(!File.exists?("foo.txt"))
                log = `svn log -v --limit 1`
                assert log =~ /setting up git-svn bridge/
                assert log =~ /   A \/bar.txt/
                assert log =~ /   D \/foo.txt/
                # Hmm, log does not have the right username, but that's because
                # we are committing to a local svn repo with no authentication.
            end
        end

    end

    def test_dupe_repo
        assert(!GSBCore.dupe_repo?("dupetest"))
        db = GSBCore.get_db
        stmt=<<-EOF
        insert into bridges 
            (
                svn_repos,
                local_wc,
                user_id,
                github_url,
                timestamp
            ) values (
                ?,
                ?,
                ?,
                ?,
                ?
            );
        EOF

        db.execute(stmt, 'dupetest', 'dupetest', 0, 'dupetest', 'dupetest')
        assert GSBCore.dupe_repo? "dupetest"
        db.execute("delete from bridges where svn_repos = ?", "dupetest")
    end

    def setup2
        Dir.chdir @ext_svn_wc do
            `svn export --username readonly --password readonly --no-auth-cache --non-interactive https://hedgehog.fhcrc.org/bioconductor/trunk/madman/Rpacks/RGalaxy`
            `svn add *`
            `svn ci -m 'add rgalaxy package'`
        end
    end

    def test_newbridge_2
        setup2

        GSBCore.new_bridge(@gitrepo, @svnrepo, "git-wins",
            $config['test_username'], $config['test_username'],
            $config['test_email'])

        
    end

end


