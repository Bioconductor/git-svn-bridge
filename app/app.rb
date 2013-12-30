require 'rubygems'    
#require 'debugger'
require 'pry'
require 'crypt/gost'
require 'base64'
require 'sinatra'
require './auth'
require 'json'
require 'nokogiri'
require 'net/smtp'
require 'open-uri'
require 'haml'
require 'fileutils'
require 'tempfile'
require 'tmpdir'
require 'open3'
require 'sqlite3'
require 'net/http'

def breakpoint()
    binding.pry if ENV['RACK_ENV'].nil?
end


#use Rack::Session::Cookie, secret: 'change_me'
enable :sessions

set :session_secret, IO.readlines("data/session_secret.txt").first

DB_FILE = "#{settings.root}/data/gitsvn.sqlite3"

    def get_db()
        if File.exists? DB_FILE
            SQLite3::Database.new DB_FILE
        else
            create_db()
        end
    end

    def create_db()
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

    def get_user_record(svn_username)
        get_db().get_first_row("select * from users where svn_username = ?",
            svn_username)
    end

    # Remove Trailing Slash
    class String
        def rts()
            self.sub(/\/$/, "")
        end
    end

    def get_repos_by_svn_path(svn_path)
        svn_path = "#{SVN_URL}#{svn_path}" unless svn_path =~ /^#{SVN_URL}/
        repos = get_db().execute("select svn_repos from bridges")
        return nil if repos.nil? or repos.empty? or \
            repos.first.nil? or repos.first.empty?
        repos = repos.map{|i| i.first}
        repos.find_all {|i| svn_path =~ /^#{i}/}
    end

    def get_bridge_from_github_url(github_url)
        get_bridge("github_url", github_url)
    end

    def get_bridge(column, path)
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

    def get_bridge_from_svn_url(svn_url)
        get_bridge("svn_repos", svn_url)
    end

    def insert_user_record(username, password, email=nil)
        get_db().execute("insert into users values (?, ?, ?)",
            username, email, encrypt(password))
    end

    def update_user_record(username, password, email)
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

    def get_user_id(username)
        puts2 "USERNAME = #{username}"
        get_db().get_first_row("select rowid from users where svn_username = ?",
            username).first
    end

# FIXME handle it if our app is located somewhere else
# (settings.root does not seem to work as expected)
HOSTNAME=`hostname`
if HOSTNAME =~ /^dhcp/
    APP_ROOT="#{ENV['HOME']}/dev/build/bioc-git-svn/app"
else
    APP_ROOT="#{ENV['HOME']}/app"
end

SVN_URL="https://hedgehog.fhcrc.org/bioconductor"

# For development, set this to /trunk/madman/RpacksTesting;
# In production, set to /trunk/madman/Rpacks.
SVN_ROOT="/trunk/madman/RpacksTesting"

f = File.open("etc/key")
key = f.readlines.first.chomp
f.close
$gost = Crypt::Gost.new(key)


helpers do

    def protected!
        halt [ 401, 'Not Authorized' ] unless logged_in?
    end

    def production?
        host = request.env['HTTP_HOST']
        if host.nil?
            puts2 "alert: request.env['HTTP_HOST'] was nil..."
            host = "nil"
        end
        if ["gitsvn.bioconductor.org", 
            "23.23.227.214", "nil"].include? host.downcase
            true
        else
            false
        end

    end

    def usessl!
        return unless production?
        unless request.secure?
            halt [301, 'use https://gitsvn.bioconductor.org instead of http://gitsvn.bioconductor.org' ]
        end
    end

    def title()
        "Bioconductor Git-SVN Bridge"
    end

    def logged_in?
        session.has_key? :username
    end


    def eq(input)
        input.gsub('"', '\"')
    end

    def loginlink()
        if (logged_in?)
            url = url('/logout')
            "Logged in as #{session[:username]}<a href='#{url}'> Log Out</a>"
        else
            url = url('/login')
            " <a href='#{url}'>Log In</a>"
        end
    end


    def msg()
        return "" if session[:message].nil? or session[:message].empty?
        m = session[:message]
        session[:message] = ''
        m
    end

    def puts2(arg)
        puts(arg)
        STDERR.puts(arg) unless HOSTNAME =~ /^dhcp/
        STDOUT.flush
        STDERR.flush
    end

    def pp2(arg)
        STDERR.puts PP.pp(arg, "")
    end

    # call to this (along with whatever is done afterwards) should be done
    # inside a lock which blocks EVERYONE. nobody should be allowed to pollute the credentials
    # between the call to cache_credentials and the svn dcommit (or whatever) afterwards
    # so call this inside a block passed to exclusive_lock().
    # Also need to ensure this is called from a git working copy.
    def cache_credentials(username, password)
        url = `git config --get svn-remote.hedgehog.url`.chomp
        puts2("in cache_credentials")
        # fixme do this on production only?
        puts2("removing auth directory...")
        FileUtils.rm_rf "#{ENV['HOME']}/.subversion/auth/svn.simple"
        system2(password, "svn log --non-interactive --limit 1 --username #{username} --password $SVNPASS #{url}")
    end

    def handle_git_push(gitpush)
        repository = gitpush['repository']['url'].rts
        monitored_repos = []
        repos, local_wc, owner, email, password, encpass = nil
        bridge = get_bridge_from_github_url(repository)
        return if bridge.nil?
        repos = repository
        local_wc = bridge[:local_wc]
        owner = bridge[:svn_username]
        email = bridge[:email]
        encpass = bridge[:encpass]
        password = decrypt(encpass)
        svn_repos = bridge[:svn_repos]

        # start locking here
        wdir = "#{ENV['HOME']}/biocsync/#{local_wc}"
        #lockfile = get_lock_file_name(wdir)
        lockfile = get_lock_file_name(svn_repos)
        commit_msg = nil
        File.open(lockfile, File::RDWR|File::CREAT, 0644) {|f|
            f.flock(File::LOCK_EX)
            Dir.chdir(wdir) do
                commit_id = nil
                run("git checkout master")
                result = run("git pull")
                if (result.first.exitstatus == 0)
                    puts2 "no problems with git pull!"
                    if result.last =~ /^Already up-to-date/
                        puts2("Nothing to do, exiting....")
                        return
                    end
                else
                    puts2 "problems with git pull, tell the user"
                    # FIXME tell the user...
                    return
                end
                run("git checkout local-hedgehog")
                commit_msg=<<"EOF"
Commit made by the git-svn bridge at https://gitsvn.bioconductor.org.
Consists of #{gitpush['commits'].length} commit(s).

Commit information:

EOF
                for commit in gitpush['commits']
                    author = commit['author']
                    commit_msg+=<<"EOF"
    Commit id: #{commit['id']}
    Commit message: 
    #{commit['message'].gsub(/\n/, "\n    ")}
    Committed by #{author['name']} <#{author['email'].sub("@", " at ")}>
    Commit date: #{commit['timestamp']}
    
EOF
                end
                puts2("git commit message is:\n#{commit_msg}")
                ###result = run %Q(git merge -m "#{eq(commit_msg)}" --commit --no-ff master)
                run %Q(git merge --no-ff  -m "#{eq(commit_msg)}" master)
                #result = run("git merge master")
                if (result.first == 0)
                    puts2 "no problems with git merge"
                else
                    puts2 "problems with git merge, tell user"
                    # tell the user
                    # FIXME - this failure isn't reported?
                    return
                end
                run("git commit -m 'make this a better message'")                
                # FIXME customize the message so --add-author-from actually works
                puts2 "before system"
                #run("git svn dcommit --add-author-from --username #{owner}")
                res = nil
                exclusive_lock() do
                    cache_credentials(owner, password)
    ###                res = system2(password, "git svn rebase --username #{owner}", true)
                    res = system2(password, "git svn dcommit --no-rebase --add-author-from --username #{owner}",
                        true)
                end
                puts2 "after system"
                if (success(res) and !commit_id.nil?)
                    commit_ids_file = "#{APP_ROOT}/data/git_commit_ids.txt"
                    FileUtils.touch(commit_ids_file)
                    f = File.open(commit_ids_file, "a")
                    puts2("trying to break circle on #{commit_id}")
                    f.puts commit_id
                end


                puts2 "i'm still here..."
            end
        }
    end

    def get_monitored_svn_repos_affected_by_commit(rev_num)
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


    def run(cmd)
        actual_command = "#{cmd} 2>&1"
        puts2 "running command: #{actual_command}"
        result = `#{actual_command}`
        result_code = $?
        puts2 "result code was: #{result_code}"
        puts2 "result was:"
        puts2 result
        [result_code, result]
    end

    def success(result)
        return (result==0) if result.is_a? Fixnum
        return false if result.nil?
        return result if (["TrueClass", "FalseClass"].include? result.class.to_s )
        return result.first==0 if result.is_a? Array and result.first.is_a? Fixnum
        result.first.exitstatus == 0
    end

    def system2(pw, cmd, echo=false)
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



    def notify_svn_merge_problem(merge_error, project, recipient, url)
        message = <<"MESSAGE_END"
From: Bioconductor Git-SVN Bridge <biocbuild@fhcrc.org>
To: #{recipient}
Subject: Git merge failure in project #{project}

This is an automated message from the SVN-Git bridge at 
the Bioconductor project.

In response to a Subversion commit to the project '#{project}',
we tried to merge the latest changes in Subversion with the 
master branch in Github and received the following error:

---
#{merge_error}
---

To fix this, click on this link:

#{url}


Please do not reply to this message. 
If you have questions, please post them to the
'bioc-devel' list.


MESSAGE_END

        # FIXME move smtp host name to config file
        Net::SMTP.start('mx.fhcrc.org') do |smtp|
            smtp.send_message message, 'biocbuild@fhcrc.org', recipient
        end
    end

    def get_lock_file_name(wc_dir)
        wc_dir.gsub!(/\/$/, "")
        wc_dir.gsub!(/^#{SVN_URL}/, "")
        lockfile =  "#{Dir.tmpdir}/#{wc_dir.gsub("/", "_").gsub(":", "-")}" 
        puts2 "get_lock_file_name returning #{lockfile}"
        lockfile
    end

    def exclusive_lock()
        lockfile = "/tmp/gitsvn-exclusive-lock-file"
        File.open(lockfile, File::RDWR|File::CREAT, 0644) {|f|
            f.flock(File::LOCK_EX)
            yield if block_given?
        }
    end


    def handle_svn_commit(repo)
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
        res = system2(password, "svn log -v --xml --limit 1 --non-interactive --no-auth-cache --username #{owner} --password $SVNPASS #{SVN_URL}#{repos}", false)
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
                exclusive_lock() do
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
Commit made by the git-svn bridge at https://gitsvn.bioconductor.org.
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


    def dupe_repo?(params)
        svn_repos = "#{params[:rootdir]}#{params[:svndir]}"
        row = 
          get_db().get_first_row("select * from bridges where svn_repos = ?",
            svn_repos)
        !row.nil?
    end


    def encrypt(input)
        encrypted = $gost.encrypt_string(input)
        Base64.encode64(encrypted)
    end

    def decrypt(input)
        decoded = Base64.decode64(input)
        $gost.decrypt_string(decoded)
    end


    def add_url_to_description(github_url, descriptionfile)
        lines = File.readlines(descriptionfile)
        lines = lines.collect {|i| i.chomp}
        lines = lines.reject {|i| i.empty?}
        nonurllines = []
        url = ""
        urlmode = false
        urlstartsat = nil
        urllinelength = nil
        lines.each_with_index do |line, idx|
            if line =~ /^URL:/
                urllinelength = 0
                urlstartsat = idx
                urlmode = true
                url = line
                next
            end
            if urlmode
                urlmode = false unless line =~ /^\s/
                if urlmode
                    url += "\n#{line}"
                    urllinelength += 1
                end
            end
        end
        url.sub!(/^URL:\s*/, "")
        if url.empty?
            nonurllines = lines
            nonurllines.push "URL: #{github_url}"
        else
            lines.each_with_index do |line, idx|
                if idx < urlstartsat || idx > (urlstartsat + urllinelength)
                    nonurllines.push line
                end
            end
            url = url.gsub /\s+/, "" if url =~ /,\s/
            if url =~ /\s/
                segs = url.split(/\s+/)
            elsif url =~ /,/
                segs = url.split(",")
            else
                segs = [url]
            end
            segs.push github_url unless segs.include? github_url
            segs[0] = "URL: #{segs.first}"
            nonurllines.push segs.join " "
        end
        nonurllines = nonurllines.reject {|i| i.empty?}
        f = open(descriptionfile, "w")
        for line in nonurllines
            f.puts line
        end
        f.close
    end


end # helpers


get '/root' do
    Dir.pwd
end


get '/login' do
    usessl!
    haml :login
end

post '/login' do
    usessl!
    f = File.open("etc/specialpass")
    specialpass = f.readlines.first.chomp
    if params[:specialpass] != specialpass
        session[:message] = "Incorrect special password."
        redirect url('/')
    end
    if auth("etc/bioconductor.authz", params['username'], params['password'])
        urls = auth("etc/bioconductor.authz",
            params[:username],
            params[:password],
            true)
        if urls.nil? or urls.empty?
            session[:message] = "You don't have permission to write to any SVN repositories."
        else
            session[:username] = params[:username]
            session[:password] = params[:password] # ahem
            url = "#{SVN_URL}#{urls.first}"
            # add user to svn auth cache
            res = system2(session[:password],
                "svn log -l 1 --non-interactive --username #{params[:username]} --password $SVNPASS #{url} > /dev/null 2>&1")
            session[:message] = "Successful Login"
            if session.has_key? :redirect_url
                redirect_url = session[:redirect_url]
                session.delete :redirect_url
                redirect to redirect_url
            end
            rec = get_user_record(params[:username])
            if (rec.nil?)
                insert_user_record(params[:username],
                    params[:password])
            end
        end
        redirect url('/')
    else
        session[:message] = "Username or Password incorrect"
        redirect url('/')
    end
end


get '/logout' do
    usessl!
    session.delete :username
    session.delete :password
    redirect url('/')
end


get '/whoami' do
    `whoami`
end

get '/pwd' do
    `pwd`
end


post '/git-push-hook' do
    # DON'T specify usessl! here!
    # make sure the request comes from one of these IP addresses:
    # 204.232.175.64/27, 192.30.252.0/22. (or is us, testing)
    unless request.ip =~ /^204\.232\.175|^192\.30\.252|^140\.107/
        puts2 "/git-push-hook: got a request from an invalid ip (#{request.ip})"
        return "You don't look like github to me."
    end
    puts2 "!!!!"
    puts2 "in /git-push-hook!!!!"
    puts2 "!!!!"
    #push = JSON.parse(params[:payload])

    # FIXME you could do more checking on the format of params[:payload]
    push = nil
    begin
        push = params[:payload]
    rescue
        msg = "malformed push payload"
        push2 msg
        return msg
    end
    log = open("data/gitpushes.log", "a")
    log.puts push
    log.close
    # FIXME trap error here
    gitpush = JSON.parse(params[:payload])

    ## make sure we're not in a vicious circle...

    commits = gitpush["commits"]
    ids = commits.map {|i| i["id"]}

    commit_ids_file = "#{APP_ROOT}/data/git_commit_ids.txt"
    if File.file?(commit_ids_file)
        File.readlines(commit_ids_file).each do |line|
            line.chomp!
            if ids.include? line
                puts2("We have already seen this git commit before!")
                puts2("Exiting from the vicious circle.")
                puts2("(commit id was #{line})")
                return
            end
        end
    end


    handle_git_push(gitpush)
    "received"
end

get '/' do
    if production? and !request.secure?
        redirect to("https://gitsvn.bioconductor.org")
    else
        haml :index
    end
end

get '/svn-commit-hook' do
    usessl!
    sleep 1 # give app a chance to cache the commit id
    # make sure request comes from a hutch ip
    unless request.ip  =~ /^140\.107|^127\.0\.0\.1$/ #  140.107.170.120 appears to be hedgehog
        puts2 "/svn-commit-hook: got a request from an invalid ip (#{request.ip})"
        return "You don't look like a hedgehog to me."
    end
    puts2 "in svn-commit-hook handler"
    repos = params[:repos]
    rev = params[:rev]
    unless repos == "/extra/svndata/gentleman/svnroot/bioconductor"
        return "not monitoring this repo"
    end
    log = open("data/svncommits.log", "a")
    log.puts("rev=#{rev}, repos=#{repos}")
    log.close
    affected_repos = get_monitored_svn_repos_affected_by_commit(rev)
    for repo in affected_repos
        svn_repo, local_wc = repo.split("\t")
        puts2 "got a commit to the repo #{svn_repo}, local wc #{local_wc}"
        handle_svn_commit(svn_repo)
    end
    "received!" 
end

get '/newproject' do
    protected!
    usessl!
    haml :newproject
end

post '/newproject' do
    protected!
    usessl!
    puts2 "in post handler for newproject"
    dupe_repo = dupe_repo?(params)
    if dupe_repo
        puts2 "dupe_repo is TRUE!!!!"
        haml :newproject_post, :locals => {:dupe_repo => true, :collab_ok => true}
    else
        puts2 "dupe_repo is FALSE!!!"
        # do stuff
        githuburl = params[:githuburl].rts
        segs = githuburl.split("/")
        gitprojname = segs.pop
        githubuser = segs.pop
        svndir = params[:svndir]
        rootdir = params[:rootdir]
        conflict = params[:conflict]

        # sanity checks:

        # verify that svn repos exists and user has read permissions on it
        svnurl = "#{rootdir}#{svndir}"
        result = system2(session[:password],
            "svn log --non-interactive --no-auth-cache --username #{session[:username]} --password $SVNPASS --limit 1 #{svnurl}")
        if result.first != 0 # repos does not exist or user does not have read privs
            return haml :newproject_post, :locals => {:svn_repo_error => true}
        end

        # verify that user has write permission to the SVN repos
        auth_urls = auth("etc/bioconductor.authz", session[:username], session[:password], true)
        write_privs = false
        if auth_urls.is_a? Array
            lookfor = "#{rootdir}#{svndir}".sub(/^#{SVN_URL}/, "")
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
            return haml :newproject_post, :locals => {:no_write_privs => true}
        end

        # verify that github url exists

        url = URI.parse(githuburl)
        req = Net::HTTP.new(url.host, url.port)
        req.use_ssl = true
        res = req.request_head(url.path)
        unless res.code =~ /^2/ # github repo not found
            return haml :newproject_post, :locals => {:invalid_github_repo => true}
        end

        # end sanity checks. 
        
        update_user_record(session[:username], session[:password],
            params[:email])
        user_id = get_user_id(session[:username])

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
            puts2 "oops, collaboration is not set up properly"
            haml :newproject_post, :locals => {:dupe_repo => false, :collab_ok => false}
        else

            # FIXME - what if git and svn project names differ?
            # fixme - make sure both repos are valid
            git_ssh_url = "git@github.com:#{githubuser}/#{gitprojname}.git"

            wdir = "#{ENV['HOME']}/biocsync/#{svndir}"
            #lockfile = get_lock_file_name(wdir, "#{rootdir}#{svndir}")
            lockfile = get_lock_file_name(svnurl)
            File.open(lockfile, File::RDWR|File::CREAT, 0644) {|f|
                f.flock(File::LOCK_EX)
                Dir.chdir("#{ENV['HOME']}/biocsync") do
                    FileUtils.rm_rf gitprojname # just in case
                    result = run("git clone #{git_ssh_url}")
                    #res = system2(session[:password],
                    #    "svn export --non-interactive --username #{session[:username]} --password $SVNPASS #{SVN_URL}#{SVN_ROOT}/#{svndir}")
                    Dir.chdir(gitprojname) do
                        repo_is_empty = `git branch`.empty?
                        res = system2(session[:password],
                            "svn log --non-interactive --limit 1 --username #{session[:username]} --password $SVNPASS #{rootdir}#{svndir}")

                        run("git config --add svn-remote.hedgehog.url #{rootdir}#{svndir}")
                        res = system2(session[:password],
                            "svn log --non-interactive --limit 1 --username #{session[:username]} --password $SVNPASS #{rootdir}#{svndir}")
                        run("git config --add svn-remote.hedgehog.fetch :refs/remotes/hedgehog")
                        exclusive_lock() do
                            cache_credentials(session[:username], session[:password])
                            res = system2(session[:password],
                                "git svn fetch --username #{session[:username]} hedgehog -r HEAD",
                                true)
                            puts2 "res:"
                            pp2 res
                        end
                        # see http://stackoverflow.com/questions/19712735/git-svn-cannot-setup-tracking-information-starting-point-is-not-a-branch
                        #run("git checkout -b local-hedgehog -t hedgehog")
                        run("git checkout hedgehog")
                        run("git checkout -b local-hedgehog")
                        # adding these two (would not be necessary in older git)
                        run("git config --add branch.local-hedgehog.remote .")
                        run("git config --add branch.local-hedgehog.merge refs/remotes/hedgehog")
                        # need password here?
                        exclusive_lock() do
                            cache_credentials(session[:username], session[:password])
                            system2(session[:password], "git svn rebase --username #{session[:username]} hedgehog")
                        end

                        branchtomerge, branchtogoto = nil
                        conflict = "svn-wins" if repo_is_empty
                        if conflict == "git-wins"
                            branchtogoto = "local-hedgehog"
                            branchtomerge = "master"
                        elsif conflict == "svn-wins"
                            branchtogoto = "master"
                            branchtomerge = "local-hedgehog"
                        else
                            # we're in trouble!
                        end


                        run("git checkout #{branchtogoto}")



                        result = run("git merge #{branchtomerge}")

                        if (result.first != 0)
                            puts2("the merge failed")
                            conflict_files = `git diff --name-only --diff-filter=U`.split("\n")


                            for file in conflict_files
                                run("git checkout --theirs #{file}")
                                run("git add #{file}")
                            end
                            # need this?
                            #run("git add .")
                            run("git commit -m 'conflicts resolved while setting up Git-SVN bridge'")

                        else
                            puts2("the merge succeeded")
                        end

                        if branchtogoto == "master"
                            run("git push origin master")
                        else
                            exclusive_lock() do
                                cache_credentials(session[:username], session[:password])
                                res = system2(session[:password],
                                    "git svn dcommit --no-rebase --add-author-from --username #{session[:username]}",
                                    true)
                            end
                        end


                        # after merging...
                        if (branchtogoto == "local-hedgehog")
                            run("git checkout master")
                        end






                    end
                end
            }

            # FIXME should we sleep for a couple seconds here?
            # to make sure that the push finishes before we register our interest in this
            # repos. Not urgent, since we wouldn't act on this push anyway, but it would
            # clean things up. NB. sometimes we don't see the expected push hook action
            # here.

            svn_repos = ""
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
            get_db().execute(stmt, "#{rootdir}#{svndir}",
                svndir, user_id, params[:githuburl].rts, timestamp)

            # Dir.chdir("#{ENV['HOME']}/biocsync/#{gitprojname}") do
            #     # we should be on master, but...
            #     run("git checkout master")
            #     if (File.exists? "DESCRIPTION")
            #         add_url_to_description(githuburl, "DESCRIPTION")
            #         run("git add DESCRIPTION")
            #         run %Q(git commit -m "automatically add github URL to DESCRIPTION")
            #         run("git push origin master")
            #     end
            # end
            
            haml :newproject_post, :locals => {:dupe_repo => false, :collab_ok => true}
        end 
    end
end

get '/test/:name' do
    unless logged_in?
        session[:redirect_url] = request.path
        redirect to('/login')
    else
        dest = request.path.sub(/^\/test/, "")
        dest
    end
end

# FIXME - um, what about binary diffs?
# need to test
get '/merge/:project/:direction' do
    usessl!
    unless logged_in?
        session[:redirect_url] = request.path
        redirect to('/login')
    end
    if HOSTNAME =~ /^dhcp/ # test code
        return erb :merge, :locals => {:files => \
            [{:name=>"file1",
            :git_contents=>Base64.encode64("file1 git contents").chomp,
            :svn_contents=>Base64.encode64("file1 svn contents").chomp},
            {:name=>"file2",
            :git_contents=>Base64.encode64("file2 git contents").chomp,
            :svn_contents=>Base64.encode64("file2 svn contents").chomp}]}
    end
    project = params[:project]
    direction = params[:direction]
    files = []
    Dir.chdir("#{ENV['HOME']}/biocsync/#{project}") do
        if direction == "svn2git"
            result = run("git checkout local-hedgehog")
            files = []
            for line in result.last.split("\n")
                if line =~ /: needs merge/
                    hsh = {}
                    file = line.split(": needs merge").first
                    file1_results = run("git show :2:#{file}")
                    file2_results = run("git show :3:#{file}")
                    hsh[:name] = file
                    hsh[:git_contents] = Base64.encode64(file2_results.last).chomp
                    hsh[:svn_contents] = Base64.encode64(file1_results.last).chomp
                    files.push hsh
                end
            end
        elsif direction == "git2svn"
        end
    end
    erb :merge, :locals => {:files => files}
end

post '/merge/:project/:direction' do
    usessl!
    # fixme - what are the implications of ensuring the user is logged in here?
    project = params[:project]
    direction = params[:direction]
    obj = JSON.parse(params[:results])
    Dir.chdir("#{ENV['HOME']}/biocsync/#{project}") do
        if direction == "svn2git"
            run("git checkout local-hedgehog")
        else
            run("git checkout master")
        end
        obj["names"].each_with_index do |name, i|
            f = File.open(name, "w")
            f.write Base64.decode64(obj["results"][i])
            f.close
            run("git add #{name}")
        end
        # FIXME better commit message (entered in editor?)
        run("git commit -m 'differences resolved in gitsvn.bioconductor.org editor'")
        commit_id = `git rev-parse HEAD`.chomp
        if (direction == "svn2git")
            result = run("git push origin master")
            if (success(result))
                commit_ids_file = "#{APP_ROOT}/data/git_commit_ids.txt"
                FileUtils.touch(commit_ids_file)
                f = File.open(commit_ids_file, "a")
                puts2("trying to break circle on #{commit_id}")
                f.puts commit_id
            end
        else
            #FIXME run cache_credentials here (in exclusive_lock)
            # FIXME need to git commit before git svn dcommit?
            run("git svn dcommit") # ???
        end
    end
    session[:message] = "Changes merged successfully."
    redirect url('/')    
end

get '/list_bridges' do
    items = [[1,2,3,4], [5,6,7,8]]
    haml :list_bridges, :locals => {:items => items}
end