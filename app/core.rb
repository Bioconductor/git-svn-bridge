require 'pp'
require 'rubygems'    
#require 'debugger'
require 'pry'
require 'crypt/gost'
require 'base64'
require_relative 'auth'
require 'json'
require 'nokogiri'
require 'net/smtp'
require 'open-uri'
require 'fileutils'
require 'tempfile'
require 'tmpdir'
require 'open3'
require 'sqlite3'
require 'net/http'

def debug?
    ENV['TESTING_GSB'] == true
end


APP_ROOT = File.expand_path(File.dirname(__FILE__))
SVN_URL="https://hedgehog.fhcrc.org/bioconductor"

f = File.open("#{APP_ROOT}/etc/key")
key = f.readlines.first.chomp
f.close
$gost = Crypt::Gost.new(key)

DB_FILE =  ENV['TESTING_GSB'] == 'true' ? "#{APP_ROOT}/data/unittest.sqlite3" :
     "#{APP_ROOT}/data/gitsvn.sqlite3"

# Remove Trailing Slash
class String
    def rts()
        self.sub(/\/$/, "")
    end
end


# Exceptions
class BadCredentialsException < Exception
end

class NoPrivilegeException < Exception
end

class InvalidLogin < Exception
end
 


module GSBCore

    def GSBCore.login(username, password)
        res = nil
        begin
            res = auth("#{APP_ROOT}/etc/bioconductor.authz", username, password)

            urls = auth("#{APP_ROOT}/etc/bioconductor.authz",
                username,
                password,
                true)
            if !urls or urls.nil? or urls.empty?
                raise InvalidLogin
            else
                rec = GSBCore.get_user_record(username)
                if (rec.nil?)
                    GSBCore.insert_user_record(username,
                        password)
                end
            end

        rescue Exception => ex 
            raise InvalidLogin
        end
    end



    def GSBCore.encrypt(input)
        encrypted = $gost.encrypt_string(input)
        Base64.encode64(encrypted)
    end

    def GSBCore.decrypt(input)
        decoded = Base64.decode64(input)
        $gost.decrypt_string(decoded)
    end


    def GSBCore.dupe_repo?(svnurl)
        row = 
          get_db().get_first_row("select * from bridges where svn_repos = ?",
            svnurl)
        !row.nil?
    end


    def GSBCore.handle_svn_commit(repo)
        repos, local_wc, owner, password, email, encpass, commit_msg = nil
        bridge = get_bridge_from_svn_url(repo)
        pp2 bridge
        repos = repo.sub(/^#{SVN_URL}/, "")
        local_wc = bridge[:local_wc]
        owner = bridge[:svn_username]
        svn_repos = bridge[:svn_repos]
        email = bridge[:email]
        encpass = bridge[:encpass]
        password = decrypt(encpass)
        puts2 "owner is #{owner}"
        res = system2(password, "svn log -v --xml --limit 1 --non-interactive --no-auth-cache --username #{owner} --password \"$SVNPASS\" #{SVN_URL}#{repos}", false)
        doc = Nokogiri::Slop(res.last)
        msg = doc.log.logentry.msg.text
        if (msg =~ /Commit made by the git-svn bridge/)
            puts2 ("no need for further action")
            return
        end
        wdir = "#{ENV['HOME']}/biocsync/#{local_wc}"
        #lockfile = get_lock_file_name(wdir, "#{SVN_URL}#{SVN_ROOT}#{repos}")
        lockfile = get_lock_file_name(svn_repos)
        File.open(lockfile, File::RDWR|File::CREAT, 0644) {|f|
            f.flock(File::LOCK_EX)
            Dir.chdir(wdir) do
                # this might result in: "Already on 'local-hedgehog"; is that OK?
                result = run("git checkout local-hedgehog")
                dump = dump = PP.pp(result, "")
                puts2 "result is #{dump}"
                project = local_wc
                direction = "svn2git"
                port = (request.port == 80) ? "" : ":#{request.port}"
                url = "#{request.scheme}://#{request.host}#{port}/merge/#{project}/#{direction}"

                if result.first.exitstatus != 0
                    puts2 "problem doing git checkout, probably need to resolve conflict"
                    notify_svn_merge_problem(result.last, project, email, url)

                    # FIXME
                    # This is a bad hack! really we want to give the user the choice of
                    # how to deal with the conflict.
                    # for line in result.last
                    #     if line =~ /: needs merge/
                    #         file = line.split(": needs merge").first
                    #         run("git checkout --theirs #{file}")
                    #         run("git add #{file}")
                    #     end
                    # end
                    # run("git checkout local-hedgehog")

                    # FIXME let the user know
                    return
                end
                #run("git svn rebase")
                puts2("before system...")
                # FIXME this currently returns false but we don't check 
                # or change behavior accordingly
                # HEY, that could be important! that could be why repos get hosed?!?
                GSBCore.lock() do
                    cache_credentials(owner, password)
                    res = system2(password, "git svn rebase --username #{owner}", true)
                    if res.last =~ /^Current branch local-hedgehog is up to date\./
                        puts2 "Nothing to do, exiting...."
                        return
                    end
                end
                ##run("git commit -a -m 'meaningless-ish commit here'")
                puts2("after system...")
                run("git checkout master")
                # problem was not detected above (result.first), but here.
                commit_msg=<<"EOF"
Commit made by the Bioconductor Git-SVN bridge.
SVN Revision: #{doc.log.logentry.attributes['revision'].value}
SVN Author: #{doc.log.logentry.author.text}
Commit Date: #{doc.log.logentry.date.text}
Commit Message:
#{doc.log.logentry.msg.text.gsub("\n", "    \n")}

EOF
                ####result = run %Q(git merge -m "#{eq(commit_msg)}" --commit --no-ff local-hedgehog)
                run("git merge local-hedgehog")
                #if (result.first == 0)
                if result.first.exitstatus == 0
                    puts2 "result was true!"
                    #run("git reset origin/master") #?????
                    # this must be unnecessary:
                    ##run("git commit -m 'gitsvn.bioconductor.org auto merge'")
                    run("git push origin master")
                else
                    puts2 "result was false!"
                    # tell user there was a problem
                    notify_svn_merge_problem(result.last, local_wc, email, url)
                end
            end 
        }
    end



    def GSBCore.lock(lockfile = "/tmp/gitsvn-exclusive-lock-file")
        File.open(lockfile, File::RDWR|File::CREAT, 0644) {|f|
            f.flock(File::LOCK_EX)
            yield if block_given?
        }
    end


    def GSBCore.get_lock_file_name(wc_dir)
        wc_dir.gsub!(/\/$/, "")
        wc_dir.gsub!(/^#{SVN_URL}/, "")
        lockfile =  "#{Dir.tmpdir}/#{wc_dir.gsub("/", "_").gsub(":", "-")}" 
        puts2 "get_lock_file_name returning #{lockfile}"
        lockfile
    end


    def GSBCore.get_monitored_svn_repos_affected_by_commit(rev_num)
        f = File.open("data/config")
        p = f.readlines().first().chomp

        # FIXME - fix this
        cmd = "svn log --xml -v --username pkgbuild --password #{p} --non-interactive " +
          "-r #{rev_num} --limit 1 https://hedgehog.fhcrc.org/bioconductor/"
        result = `#{cmd}`
        #puts2("after system")
        #result = run(cmd)
        xml_doc = Nokogiri::XML(result)
        paths = xml_doc.xpath("//path")
        changed_paths = []
        for path in paths
            changed_paths.push path.children.to_s
        end

        ret = {}
        for item in changed_paths
            repos = get_repos_by_svn_path(item)
            next if repos.nil?
            for repo in repos
                ret[repo] = 1
            end
        end
        ret.keys
    end



    def GSBCore.handle_git_push(push)
        repository = push["repository"]["url"] #.rts?

        if push.has_key? "zen"
            puts2 "responding to ping"
            return "#{obj["zen"]} Wow, that's pretty zen!"
        end

        if push.has_key? "ref" and push["ref"] != "refs/heads/master"
            return "ignoring push to refs other than refs/heads/master"
        end

        monitored_repos = []
        repos, local_wc, owner, email, password, encpass = nil
        bridge = get_bridge_from_github_url(repository)
        if bridge.nil?
            return "There is no bridge for this repos."
        end

        local_wc = bridge[:local_wc]
        owner = bridge[:svn_username]
        email = bridge[:email]
        encpass = bridge[:encpass]
        password = decrypt(encpass)
        svn_repos = bridge[:svn_repos]

        # start locking here
        wdir = "#{ENV['HOME']}/biocsync/git/#{local_wc}"
        #lockfile = get_lock_file_name(wdir)
        lockfile = get_lock_file_name(svn_repos)
        commit_msg = nil
        GSBCore.lock(lockfile) do
            commit_message = nil
            Dir.chdir(wdir) do
                res = run("git --no-pager log HEAD")
                commit_before_pull = res.last.split("\n").first.split(" ").last
                res = run("git pull")
                if res.last.strip == "Already up-to-date."
                    return "git pull says I'm already up to date."
                end
                res = run("git checkout master") # just to be safe
                res = GSBCore.run(%Q(git --no-pager log --pretty=format:"Commit id: %H%nCommit message: %s%n%b%nCommitted by: %cn%nAuthor Name: %an%nCommit date: %ci%nAuthor date: %ai%n" #{commit_before_pull}..HEAD))
                commits_for_push = res.last.gsub(/\n\nCommitted by:/, "\nCommitted by:")
                num_commits = 0
                commits_for_push.split("\n").find_all {|i| num_commits += 1 if  i =~ /^Commit id: /}
                pl = num_commits > 1 ? "s" : ""
                commit_message =<<"EOT"
Commit made by the Bioconductor Git-SVN bridge.
Consists of #{num_commits} commit#{pl}.

Commit information:

#{commits_for_push}
EOT

            end

            svn_wdir = "#{ENV['HOME']}/biocsync/svn/#{local_wc}"
            Dir.chdir svn_wdir do
                # just to be safe, do an svn up.
                # we should be moderately concerned if this pulls down anything new.
                res = system2(password, "svn up #{svnflags(owner)}")
                if res.last.split("\n").length > 1
                    puts2 "svn up (in handle_git_push()) pulled down new content!"
                end
                diff = get_diff(wdir, svn_wdir)
                begin
                    resolve_diff wdir, svn_wdir, diff, "svn"
                    svn_commit(svn_wdir, commit_message)
                rescue Exception => ex
                    if ex.message =~ /^Failed to git/
                        return "failed to 'git rm' an item"
                    elsif ex.message =~ /^Failed to svn/
                        return "failed to 'svn delete an item"
                    elsif ex.message == "svn_commit_failed"
                        return "svn commit failed"
                    else
                        return "unknown error"
                    end
                    # FIXME should probably do some more cleanup here?
                    # svn revert things to where they were before we 
                    # tried to resolve_diff?
                end
            end
        end # lock

        "received"
    end # handle_git_push


    def GSBCore.eq(input)
        input.gsub('"', '\"')
    end


    def GSBCore.get_wc_dirname(svn_url)
        if svn_url =~ /#{SVN_URL}/
            return svn_url.sub(SVN_URL, "").gsub("/", "_").sub(/^_/, "")
        else
            return svn_url.sub(/^file:\/\//i, "").gsub("/", "_")
        end
    end


    def GSBCore.get_user_id(username)
        row = get_db().get_first_row("select rowid from users where svn_username = ?",
            username)
        raise "unknown user: #{username}" if row.nil?
        row.first
    end



    def GSBCore.update_user_record(username, password, email)
        row = get_user_record(username)
        return if row.nil? # this should not happen
        newrow = row.dup
        if row[1].nil? or row[1] != email
            newrow[1] = email
        end
        oldpw = decrypt(row.last)
        if (password != oldpw)
            newrow[2] = encrypt(password)
        end
        if newrow != row
            stmt=<<-"EOF"
                update users set
                    email = ?,
                    encpass = ?
                where svn_username = ?
            EOF
            get_db().execute(stmt, newrow[1], newrow[2], username)
        end
    end



    def GSBCore.insert_user_record(username, password, email=nil)
        get_db().execute("insert into users values (?, ?, ?)",
            username, email, encrypt(password))
    end

    def GSBCore.get_bridge_from_svn_url(svn_url)
        get_bridge("svn_repos", svn_url)
    end



    def GSBCore.get_bridge(column, path)
        path = path.rts if column == "github_url"
        stmt=<<-"EOF"
            select * from bridges, users
            where bridges.#{column} = ?
            and bridges.user_id = users.rowid;
        EOF
        columns, rows = get_db().execute2(stmt, path)
        hsh = {}
        return nil if rows.nil?
        columns.each_with_index do |col, i|
            hsh[col.to_sym] = rows[i]
        end
        hsh
    end


    def GSBCore.get_bridge_from_github_url(github_url)
        get_bridge("github_url", github_url)
    end


    def get_repos_by_svn_path(svn_path)
        svn_path = "#{SVN_URL}#{svn_path}" unless svn_path =~ /^#{SVN_URL}/
        repos = get_db().execute("select svn_repos from bridges")
        return nil if repos.nil? or repos.empty? or \
            repos.first.nil? or repos.first.empty?
        repos = repos.map{|i| i.first}
        repos.find_all {|i| svn_path =~ /^#{i}/}
    end



    def GSBCore.get_user_record(svn_username)
        get_db().get_first_row("select * from users where svn_username = ?",
            svn_username)
    end


    def GSBCore.create_db()
        db = SQLite3::Database.new DB_FILE
        db.execute_batch <<-EOF
            create table bridges (
                svn_repos text unique not null,
                local_wc text not null, 
                user_id integer not null, 
                github_url text not null,
                timestamp text not null
            );

            create table users (
                svn_username text unique not null,
                email text null,
                encpass text not null
            );
        EOF
        db
    end




    def GSBCore.get_db()
        if File.exists? DB_FILE
            db = SQLite3::Database.new DB_FILE
            res = db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='bridges';")
            return create_db() if res.empty?
            db
        else
            create_db()
        end
    end


    def GSBCore.puts2(arg)
        puts(arg)
        STDOUT.flush
        if (ENV["RUNNING_SINATRA"] == "true")
            STDERR.puts(arg)
            STDERR.flush
        end
    end

    def GSBCore.pp2(arg)
        puts PP.pp(arg, "")
        if (ENV["RUNNING_SINATRA"] == "true")
            STDERR.puts PP.pp(arg, "")
        end
    end


    def GSBCore.system2(pw, cmd, echo=false)
        if echo
            cmd = "echo $SVNPASS | #{cmd}"
        end
        env = {"SVNPASS" => pw}
        puts2 "running SYSTEM command: #{cmd}"
        begin
            stdin, stdout, stderr, thr = Open3.popen3(env, cmd)
        rescue
            puts2 "Caught an error running system command"
        end
        result = thr.value.exitstatus
        puts2 "result code: #{result}"
        stdout_str = stdout.gets(nil)
        stderr_str = stderr.gets(nil)
        # FIXME - apparently not all output (stderr?) is shown when there is an error
        puts2 "stdout output:\n#{stdout_str}"
        puts2 "stderr output:\n#{stderr_str}"
        puts2 "---system2() done---"
        [result, stderr_str, stdout_str] #though it gets returned ok
    end

    def GSBCore.run(cmd)
        actual_command = "#{cmd} 2>&1"
        puts2 "running command: #{actual_command}"
        result = `#{actual_command}`
        result_code = $?
        puts2 "result code was: #{result_code}"
        puts2 "result was:"
        puts2 result
        [result_code, result]
    end

    def GSBCore.success(result)
        return (result==0) if result.is_a? Fixnum
        return false if result.nil?
        return result if (["TrueClass", "FalseClass"].include? result.class.to_s )
        return result.first==0 if result.is_a? Array and result.first.is_a? Fixnum
        result.first.exitstatus == 0
    end

    def GSBCore.bridge_sanity_checks(githuburl, svnurl, conflict, username, password)
        segs = githuburl.split("/")
        gitprojname = segs.pop
        githubuser = segs.pop

        # verify that svn repos exists and user has read permissions on it
        local_wc = get_wc_dirname(svnurl)
        result = system2(password,
            "svn log --non-interactive --no-auth-cache --username #{username} --password \"$SVNPASS\" --limit 1 #{svnurl}")
        if result.first != 0 # repos does not exist or user does not have read privs
            raise "repo_error"
        end

        # verify that user has write permission to the SVN repos
        auth_urls = auth("#{APP_ROOT}/etc/bioconductor.authz", username, password, true)
        write_privs = false
        if auth_urls.is_a? Array
            lookfor = svnurl.sub(/^#{SVN_URL}/, "")
            for auth_url in auth_urls
                if lookfor =~ /^#{auth_url}/
                    write_privs = true
                    break
                end
            end
        else
            write_privs = false
        end

        unless write_privs # no write privs to specified svn dir
            raise "no_write_privs"
        end

        # verify that github url exists

        url = URI.parse(githuburl)
        req = Net::HTTP.new(url.host, url.port)
        req.use_ssl = true
        res = req.request_head(url.path)
        unless res.code =~ /^2/ # github repo not found
            raise "no_github_repo"
        end

        data = URI.parse("https://api.github.com/repos/#{githubuser}/#{gitprojname}/collaborators").read
        obj = JSON.parse(data)
        ok = false
        for item in obj
            if item.has_key? "login" and item["login"] == 'bioc-sync'
                ok = true
                break
            end
        end
        unless ok
            raise "bad_collab"
        end

    end


    def GSBCore.new_bridge(githuburl, svnurl, conflict, username, password, email)
        if dupe_repo?(svnurl)
            raise "dupe_repo"
        end

        unless ENV['TESTING_GSB'] == 'true'
            bridge_sanity_checks(githuburl, svnurl, conflict, username, password)
        end

        segs = githuburl.split("/")
        gitprojname = segs.pop
        githubuser = segs.pop

        git_ssh_url = nil
        if (githuburl =~ /https:\/\/github.com/i)
            git_ssh_url = "git@github.com:#{githubuser}/#{gitprojname}.git"
        else
            git_ssh_url = githuburl
        end

        local_wc = get_wc_dirname(svnurl)

        lockfile = get_lock_file_name(svnurl)
        GSBCore.lock(lockfile) do
            Dir.chdir "#{ENV['HOME']}/biocsync" do
                Dir.chdir("git") do
                    raise "git_wc_exists" if File.exists? local_wc # not caught!
                    res  = run("git clone #{git_ssh_url} #{local_wc}")
                    raise "git_clone_failed" unless success(res)
                    Dir.chdir(local_wc) do
                        repo_is_empty = false
                        res = run("git branch")
                        repo_is_empty = true if res.last.empty?
                        if repo_is_empty
                            if conflict == "git-wins"
                                # we could raise an error here, but let's
                                # just do what they meant to do
                                conflict = "svn-wins"
                            end
                        else
                            if res.last =~ / master\n/
                                run("git checkout master")
                            else
                                raise "no_master_branch_in_non_empty_git_repo"
                            end
                        end
                    end
                end
                Dir.chdir("svn") do
                    res = system2(password, "svn co #{svnflags username} #{svnurl} #{local_wc}")
                end
                src, dest, dest_vcs = nil
                if conflict == "git-wins"
                    src = "git/#{local_wc}"
                    dest = "svn/#{local_wc}"
                    dest_vcs = "svn"
                elsif conflict == "svn-wins"
                    src = "svn/#{local_wc}"
                    dest = "git/#{local_wc}"
                    dest_vcs = "git"
                else
                    raise "invalid conflict value"
                end
                diff = get_diff src, dest
                resolve_diff src, dest, diff, dest_vcs
                if dest_vcs == "git"
                    git_commit_and_push(dest, "setting up git-svn bridge")
                else
                    svn_commit(dest, "setting up git-svn bridge")
                end
            end

            update_user_record(username, password, email)
            user_id = get_user_id(username)
            add_bridge_record(svnurl, local_wc, githuburl, user_id)


        end

    end

    def GSBCore.delete_bridge(local_wc)
        get_db().execute("delete from bridges where local_wc = ?", local_wc)
        Dir.chdir "#{ENV['HOME']}/biocsync" do
            FileUtils.rm_rf "git/#{local_wc}"
            FileUtils.rm_rf "svn/#{local_wc}"
        end
    end

    def GSBCore.add_bridge_record(svn_repos, local_wc, github_url, user_id)
        t = Time.now
        timestamp = t.strftime "%Y-%m-%d %H:%M:%S.%L"            
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
        get_db().execute(stmt, svn_repos,
            local_wc, user_id, github_url.rts, timestamp)
    end

    # FIXME git pull first?
    def GSBCore.git_commit_and_push(git_wc_dir, commit_comment)
        commit_file = Tempfile.new "gsb_git_commit_message"
        commit_file.write commit_comment
        commit_file.close
        Dir.chdir git_wc_dir do
            res = run("git commit -F #{commit_file.path}")
            raise "git_commit_failed" unless success(res)
            res = run("git push")
            raise "push_failed" unless success(res)
        end
        commit_file.unlink
    end

    # FIXME svn up first?
    def GSBCore.svn_commit(svn_wc_dir, commit_comment)
        commit_file = Tempfile.new "gsb_svn_commit_message"
        commit_file.write commit_comment
        commit_file.close
        Dir.chdir svn_wc_dir do
            res = run("svn commit -F #{commit_file.path}")
            raise "svn_commit_failed" unless success(res)
        end
        commit_file.unlink
    end

    def GSBCore.svnflags(username)
        " --username #{username} --password $SVNPASS --non-interactive --no-auth-cache "
    end

    def GSBCore.handle_svn_commit()
    end

    def GSBCore.check_for_svn_updates()
    end

    def GSBCore.check_for_git_updates()
    end

    def GSBCore.encrypt_password()
    end

    def GSBCore.decrypt_password()
    end

    # should be run in ~/biocsync
    def GSBCore.get_diff(src, dest)
        to_be_deleted = []
        to_be_added = []
        to_be_copied = []
        raise "src dir #{src} doesn't exist!" unless File.directory? src
        raise "dest dir #{dest} doesn't exist!" unless File.directory? dest
        res = run("diff -rq -x .git -x .svn #{src} #{dest}")
        lines = res[1].split "\n"
        for line in lines
            if line =~ /^Only in #{src}:/
                to_be_added.push(line.sub("Only in #{src}: ", ""))
            elsif line =~ /^Only in #{dest}:/
                to_be_deleted.push(line.sub("Only in #{dest}: ", ""))
            elsif line =~ /^Files/
                segs = line.gsub(/^Files | differ$/, "").split(" and ")
                to_be_copied.push segs.first.sub(/^#{src}\//, "")
            else
                # dunno
            end
        end
        return nil if to_be_copied.empty? and 
            to_be_deleted.empty? and to_be_added.empty?
        return {:to_be_added => to_be_added, :to_be_deleted => to_be_deleted,
            :to_be_copied => to_be_copied}
    end

    def GSBCore.gitname(name)
        name.sub(/^git\//, "")
    end

    # should also be run from ~/biocsync
    def GSBCore.resolve_diff(src, dest, diff, dest_vcs)
        src = File.expand_path src
        dest = File.expand_path dest
        if diff.nil?
            puts2 "nothing to do!"
            return
        end
        src_vcs = dest_vcs == "git" ? "svn" : "git"
        for item in diff[:to_be_deleted]
            if dest_vcs == "git"
                gitname = gitname(item)
                Dir.chdir dest do
                    flag = File.directory?(item) ? " -r " : ""
                    res = run("git rm #{flag} #{item}")
                    unless success(res)
                        raise "Failed to git rm #{flag} #{gitname}!"
                    end
                end
            else # svn
                Dir.chdir dest do
                    res = run("svn delete #{item}")
                    unless success(res)
                        raise "Failed to svn delete #{item}!"
                    end
                end
            end
        end

        adds = diff[:to_be_copied] + diff[:to_be_added]

        for item in adds
            # copy

            if File.directory? "#{src}/#{item}"
                res = run("rsync -a --exclude=.svn --exclude=.git #{src}/#{item}/ #{dest}/#{item}")
            else
                FileUtils.cp "#{src}/#{item}", "#{dest}/#{item}"
            end

            if dest_vcs == "git"
                Dir.chdir dest do

                    # skip empty directories, git does not deal
                    if File.exists? item and File.directory? item and 
                      Dir.entries(item).length==2
                        next
                    end

                    res = system2("", "git add --dry-run #{item}")
                    # weed out baddies
                    if res[1] =~ /^The following paths are ignored/ 
                        # don't add this one, it's ignored
                        # by .gitignore
                        # instead, delete it
                        if File.directory? item
                            FileUtils.rm_rf item
                        else
                            FileUtils.rm item
                        end
                        next
                    end
                    res = run("git add #{item}")
                    unless success(res)
                        raise "Failed to git add #{item}!"
                    end
                end
            else # svn
                Dir.chdir dest do
                    if diff[:to_be_added].include? item
                        res = run("svn add #{item}")
                        unless success(res)
                            raise "Failed to svn add #{item}!"
                        end
                    end
                end
            end
        end
    end

    def GSBCore.coretest
    end

end