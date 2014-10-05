# encoding: utf-8
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
            raise InvalidLogin unless res
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
        #repos = repo.sub(/^#{SVN_URL}/, "")
        local_wc = bridge[:local_wc]
        owner = bridge[:svn_username]
        svn_repos = bridge[:svn_repos]
        email = bridge[:email]
        encpass = bridge[:encpass]
        password = decrypt(encpass)
        puts2 "owner is #{owner}"
        res = system2(password, "svn log -v --xml --limit 1 --non-interactive --no-auth-cache --username #{owner} --password $SVNPASS #{svn_repos}", false)
        # doc = Nokogiri::Slop(res.last)
        # msg = doc.log.logentry.msg.text
        # if (msg =~ /Commit made by the git-svn bridge/)
        #     puts2 ("no need for further action")
        #     return
        # end
        wdir = "#{ENV['HOME']}/biocsync/svn/#{local_wc}"
        destdir = "#{ENV['HOME']}/biocsync/git/#{local_wc}"
        lockfile = get_lock_file_name(svn_repos)
        lock(lockfile) do
            Dir.chdir(wdir) do
                res = system2(password, "svn info #{svnflags(owner)}")
                old_rev_num = res.last.split("\n").find{|i| 
                    i =~ /^Revision:/}.sub("Revision: ", "")

                res = system2(password, "svn up #{svnflags(owner)}")
                new_rev_num = 
                    res.last.split(/At revision |Updated to revision /).last.strip.sub(".", "")
                if (old_rev_num == new_rev_num)
                    return "no new svn commits!"
                end

                range = "#{old_rev_num.to_i + 1}:#{new_rev_num}"
                res = system2(password, "svn log --xml -r #{range} #{svnflags(owner)}")
                xml = res.last
                doc = Nokogiri::XML(xml)
                logentries = doc.css("logentry")
                msg = "Commit made by the Bioconductor Git-SVN bridge.\n\n"
                pl = logentries.length > 1 ? "s" : ""
                msg += "Consists of #{logentries.length} commit#{pl}.\n\n"
                msg += "Commit information:\n\n"
                for logentry in logentries
                    msg += "SVN Revision number: #{logentry.attribute("revision").value}\n"
                    msg += "Commit message:\n#{logentry.css("msg").text}\n"
                    msg += "Committed by #{logentry.css("author").text}\n"
                    msg += "Committed at: #{logentry.css("date").text}\n\n"
                end
                diff = get_diff(wdir, destdir)
                resolve_diff(wdir, destdir, diff, "git")
                git_commit_and_push(destdir, msg)
                return "success"
            end
        end
    end



    def GSBCore.lock(lockfile = "/tmp/gitsvn-exclusive-lock-file")
        File.open(lockfile, File::RDWR|File::CREAT, 0644) {|f|
            f.flock(File::LOCK_EX)
            yield if block_given?
        }
    end


    def GSBCore.get_lock_file_name(wc_dir)
        lockfile = wc_dir.gsub(/\/$/, "")
        lockfile = lockfile.gsub(/^#{SVN_URL}/, "")
        lockfile =  "#{Dir.tmpdir}/#{lockfile.gsub("/", "_").gsub(":", "-")}" 
        puts2 "get_lock_file_name returning #{lockfile}"
        lockfile
    end


    def GSBCore.get_monitored_svn_repos_affected_by_commit(rev_num,
      repos="/extra/svndata/gentleman/svnroot/bioconductor")
        svnroot = nil
        default_repos = "/extra/svndata/gentleman/svnroot/bioconductor"
        default_svn_url = "https://hedgehog.fhcrc.org/bioconductor/"
        if repos == default_repos
            svnroot = default_svn_url
        else
            svnroot = "file://#{repos}/".sub(/\/\/$/, "/")
        end
        f = File.open("#{APP_ROOT}/data/config")
        p = f.readlines().first().chomp

        # FIXME - fix this
        cmd = "svn log --xml -v --username pkgbuild --password #{p} --non-interactive " +
          "-r #{rev_num} --limit 1 #{svnroot}"
        result = `#{cmd}`
        #result = run(cmd)
        xml_doc = Nokogiri::XML(result)
        paths = xml_doc.xpath("//path")
        changed_paths = []
        for path in paths
            changed_paths.push path.children.to_s
        end

        ret = {}

        if repos == default_repos
            # FIXME this is not (yet) unit-tested
            for item in changed_paths
                repos = get_repos_by_svn_path(item)
                next if repos.nil?
                for repo in repos
                    ret[repo] = 1
                end
            end
        else
            svn_repos = GSBCore.get_db.execute("select svn_repos from bridges").first
            raise "no bridges defined!" if svn_repos.nil?
            for svn_repo in svn_repos
                if svn_repo == "file://#{repos}"
                    ret[svn_repo] = 1
                end
            end
        end
        return ret.keys
    end

    def GSBCore.clean_commit_message(msg)
        outlines = []
        msgmode = false
        append = true
        for line in msg.split("\n")
            append = true
            if msgmode
                line = "    " + line
            end

            if line =~ /^___COMMITMSG_FIRSTLINE___:/
                # puts "got commit msg firstline"
                line.sub! /^___COMMITMSG_FIRSTLINE___:/, "    "
                line = line + "\n"
            end

            if line.strip() == "___END_COMMIT_MSG___"
                # puts "hit end msg"
                msgmode = false
                append = false
            end

            if line.strip == "___COMMITMSG_REMAINDER___:"
                # puts "hit remainder"
                append = false
            else
                if line =~ /^___COMMITMSG_REMAINDER___:/
                    # puts "hit remainder w/content"
                    line = line.sub /^___COMMITMSG_REMAINDER___:/, "    "
                    msgmode = true
                end
            end
            outlines << line if append
        end
        return(outlines.join("\n"))
    end

    def GSBCore.handle_git_push(push)
        if push.has_key? "zen"
            puts2 "responding to ping"
            return "#{push["zen"]} Wow, that's pretty zen!"
        end


        repository = push["repository"]["url"] #.rts?


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
                res = run("git pull origin master")
                if res.last.strip == "Already up-to-date."
                    return "git pull says I'm already up to date."
                end
                res = run("git checkout master") # just to be safe
                res = GSBCore.run(%Q(git --no-pager log --pretty=format:"Commit id: %H%n%n___COMMITMSG_FIRSTLINE___:%s%n___COMMITMSG_REMAINDER___:%b%n___END_COMMIT_MSG___%nCommitted by: %cn%nAuthor Name: %an%nCommit date: %ci%nAuthor date: %ai%n" #{commit_before_pull}..HEAD))
                commits_for_push = res.last.gsub(/\n\nCommitted by:/, "\nCommitted by:")
                commits_for_push = GSBCore.clean_commit_message(commits_for_push)
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
                    svn_commit(svn_wdir, commit_message, owner)
                rescue Exception => ex
                    send_exception_email("handle_git_push failed", ex, repository)
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

    def GSBCore.get_user_record_from_id(id)
        get_db.get_first_row("select * from users where rowid = ?", id)
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
        cmd = cmd.gsub "$SVNPASS", '"$SVNPASS"'
        if echo
            cmd = "echo $SVNPASS | #{cmd}"
        end
        env = {"SVNPASS" => pw}
        puts2 "running SYSTEM command: #{cmd}"
        begin
            stdin, stdout, stderr, thr = Open3.popen3(env, cmd)
        rescue
            send_exception_email("system2 error", ex, cmd)
            puts2 "Caught an error running system command"
        end
        stdout_str = stdout.gets(nil)
        stderr_str = stderr.gets(nil)
        result = thr.value.exitstatus
        puts2 "result code: #{result}"
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

    def GSBCore.production?
        if `hostname` =~ /^ip/
            true
        else
            false
        end
    end

    def GSBCore.web?
        ENV.has_key? 'RACK_ENV'
    end

    def GSBCore.send_exception_email(subject, ex, more=nil)
        unless GSBCore.web? and GSBCore.production?
            puts2 "not sending email, not on web and production"
            return
        end
        body=<<"MESSAGE_END"
Got an exception of class #{ex.class}.

Message: #{ex.message}

Backtrace:
#{ex.backtrace}


MESSAGE_END
        unless more.nil?
            body += "\nMore:\n#{more.pretty_inspect}"
        end
        send_email(subject, body)
    end

    def GSBCore.send_email(subject, msg)
        to_email = "dtenenba@fhcrc.org"
        to_name = "Dan Tenenbaum"
        from_email = "biocbuild@fhcrc.org"
        from_name = "Git SVN Bridge"

        message = <<"MESSAGE_END"
From: #{from_name} <#{from_email}>
To: #{to_name} <#{to_email}>
Subject: #{subject}

#{msg}
MESSAGE_END
        
        Net::SMTP.start('mx.fhcrc.org') do |smtp|
          smtp.send_message message, from_email, 
                                     to_email
        end
    end


    def GSBCore.bridge_sanity_checks(githuburl, svnurl, conflict, username, password)
        segs = githuburl.split("/")
        gitprojname = segs.pop
        githubuser = segs.pop

        # verify that svn repos exists and user has read permissions on it
        local_wc = get_wc_dirname(svnurl)
        result = system2(password,
            "svn log --non-interactive --no-auth-cache --username #{username} --password $SVNPASS --limit 1 #{svnurl}")
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
        # this is just a wrapper for error handling and cleanup.
        # open to suggestions for another way to do this.
        begin
            GSBCore._new_bridge(githuburl, svnurl, conflict,
                username, password, email)
        rescue Exception => ex
            local_wc = get_wc_dirname(svnurl)
            GSBCore.delete_bridge(local_wc)
            send_exception_email("exception creating bridge", ex,
                {:githuburl => githuburl, :svnurl => svnurl, :conflict => conflict,
                    :username => username, :email => email})
            raise ex.message
        end
    end

    def GSBCore._new_bridge(githuburl, svnurl, conflict, username, password, email)
        if dupe_repo?(svnurl)
            raise "dupe_repo"
        end

        unless ENV['TESTING_GSB'] == 'true' or ENV['SKIP_SANITY_CHECKS'] == 'true'
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
                    unless success(res)
                        raise "git_clone_failed"
                    end
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
                            run("git checkout master")
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
                unless diff.nil?
                    resolve_diff src, dest, diff, dest_vcs
                    if dest_vcs == "git"
                        git_commit_and_push(dest, "setting up git-svn bridge")
                    else
                        svn_commit(dest, "setting up git-svn bridge", username, true)
                    end
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
    def GSBCore.git_commit_and_push(git_wc_dir, commit_comment, from_bridge=false)
        commit_file = Tempfile.new "gsb_git_commit_message"
        commit_file.write commit_comment
        commit_file.close
        Dir.chdir git_wc_dir do
            res = run("git commit -F #{commit_file.path}")
            unless success(res)
                if res.last =~ /nothing to commit, working directory clean/
                    commit_file.unlink
                    return
                else
                    raise "git_commit_failed"
                end
            end
            res = run("git push origin master")
            raise "push_failed" unless success(res)
        end
        commit_file.unlink
    end

    # FIXME svn up first?
    def GSBCore.svn_commit(svn_wc_dir, commit_comment, svn_username, from_bridge=false)
        user = GSBCore.get_user_record(svn_username)
        pw = GSBCore.decrypt user.last
        commit_file = Tempfile.new "gsb_svn_commit_message"
        commit_file.write commit_comment
        commit_file.close
        Dir.chdir svn_wc_dir do
            res = run("svn status")
            files = res.last.split("\n").map{|i|i.sub(/^.\s+/, "")}
            seen = []
            for file in files
                if seen.include? file.downcase
                    unless from_bridge
                        # FIXME - email the user about this problem
                    end
                    raise "filename_case_conflict: #{file}"
                end
                seen << file.downcase
            end
            res = system2(pw,
                "svn commit -F #{commit_file.path} #{svnflags(svn_username)}")
            raise "svn_commit_failed" unless success(res)
        end
        commit_file.unlink
    end

    def GSBCore.svnflags(username)
        " --username #{username} --password $SVNPASS --non-interactive --no-auth-cache "
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

        unless File.directory? src
            raise "src dir #{src} doesn't exist!"
        end

        unless File.directory? dest
            raise "dest dir #{dest} doesn't exist!"
        end
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

    def GSBCore.handle_svn_ignores
        res = run("svn status --no-ignore")
        ignores = res.last.split("\n").find_all{|i|i=~/^I/}
        filespec = ""
        for ignore in ignores

            FileUtils.rm_rf(ignore.sub(/^I\s+/, ""))
            # is rm_rf overkill?
        end
    end

    def GSBCore.handle_git_ignores
        res = run("git ls-files --others -i --exclude-standard")
        for file in res.last.split("\n")
            FileUtils.rm_rf file
        end
    end

    def GSBCore.resolve_diff(src, dest, diff, dest_vcs)
        src = File.expand_path src
        dest = File.expand_path dest
        rsync_src = "#{src}/".sub(/\/\/$/, "/")

        if diff.nil?
            puts2 "nothing to do!"
            return
        end
        src_vcs = dest_vcs == "git" ? "svn" : "git"

        res = run("rsync -av --checksum --delete --exclude=.svn --exclude=.git #{rsync_src} #{dest}")
        unless success(res)
            raise "rsync_failed"
        end
        if dest_vcs == "svn"
            Dir.chdir dest do


                res = run("svn status")
                addme = res.last.split("\n").find_all{|i|i=~/^\?/}
                deleteme = res.last.split("\n").find_all{|i|i=~/^!/}

                # handle additions
                filespec = ""
                for item in addme
                    item.sub! /^\?\s+/, ""
                    filespec += %Q( "#{item}" )
                end
                unless filespec.empty?
                    res = run("svn add #{filespec}")
                end

                # handle deletions
                filespec = ""
                for item in deleteme
                    item.sub! /^!\s+/, "" # hopefully filename doesn't
                                          # start with whitespace
                    filespec += %Q( "#{item}" )
                end
                unless filespec.empty?
                    res = run("svn delete #{filespec}")
                    unless success(res)
                        raise "svn_delete_failed"
                    end
                end
                GSBCore.handle_svn_ignores()
            end
        else # git
            Dir.chdir dest do
                res = run("git add --all .")
                res = run("git status")
                deleteme = res.last.split("\n").find_all{|i|i=~/^ D/}
                filespec = ""
                for item in deleteme
                    item.sub! /^ D /, ""
                    filespec += %Q( "#{item}" )
                end
                unless filespec.empty?
                    res = run("git delete #{filespec}")
                end
                GSBCore.handle_git_ignores()
            end
        end
    end

    def GSBCore.coretest
    end

end


class BridgeList
    include Enumerable

    include GSBCore

    def initialize
        @data = GSBCore.get_db.execute2("select * from bridges")
        @columns = @data.shift
    end

    def hashify(row)
        h = {}
        @columns.each_with_index do |col, i|
            h[col.to_sym] = row[i]
        end
        h
    end

    def each(&block)
        @data.each do |item|
            block.call(hashify(item))
        end
    end
end 
