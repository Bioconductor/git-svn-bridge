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

def breakpoint()
    binding.pry if ENV['RACK_ENV'].nil?
end


#use Rack::Session::Cookie, secret: 'change_me'
enable :sessions

set :session_secret, IO.readlines("data/session_secret.txt").first

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

    def cache_credentials(username, password)
        url = `git config --get svn-remote.hedgehog.url`.chomp
        puts2("in cache_credentials")
        system2(password, "svn log --limit 1 --username #{username} --password $SVNPASS #{url}")
    end

    def handle_git_push(gitpush)
        repository = gitpush['repository']['url'].sub(/\/$/, "")
        monitored_repos = []
        repos, local_wc, owner, email, password, encpass = nil
        File.readlines("data/monitored_git_repos.txt").each do |line|

            repos, local_wc, owner, email, encpass = line.chomp.split("\t")
            password = decrypt(encpass)
            repos.sub! /\/$/, ""
        end
        return if repos.nil? # we're not monitoring this repo

        # start locking here
        wdir = "#{ENV['HOME']}/biocsync/#{local_wc}"
        #lockfile = get_lock_file_name(wdir)
        lockfile = get_lock_file_name(local_wc)
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
                cache_credentials(owner, password)
###                res = system2(password, "git svn rebase --username #{owner}", true)
                res = system2(password, "git svn dcommit --no-rebase --add-author-from --username #{owner}",
                    true)
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

        #cmd = "svn log --username pkgbuild --non-interactive -v --xml -r " + 
        #{}"#{rev_num} --limit 1 https://hedgehog.fhcrc.org/bioconductor/"
        #puts2("before system")
        #res = system({"SVNPASS" => p},
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
        monitored_repos = []
        File.readlines('data/monitored_svn_repos.txt').each do |line|
            monitored_repos.push line.chomp
        end
        ret = {}
        for item in changed_paths
            for repo in monitored_repos
                if item =~ /^#{repo.split("\t").first}/
                    ret[repo] = 1
                end
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
            puts "Caught an error running system command"
        end
        result = thr.value.exitstatus
        puts2 "result code: #{result}"
        stdout_str = stdout.gets(nil)
        stderr_str = stderr.gets(nil)
        puts2 "stdout output:\n#{stdout_str}"
        puts2 "stderr output:\n#{stderr.gets(nil)}"
        puts2 "---system2() done---"
        [result, stderr_str, stdout_str]
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

    # FIXME - wc_dir may match a project in more than one root dir
    # but this shouldn't fail, it just means we are being overzealous
    def get_lock_file_name(wc_dir)
        lockfile =  "#{Dir.tmpdir}/#{wc_dir.gsub("/", "_").gsub(":", "-")}" 
        puts2 "get_lock_file_name returning #{lockfile}"
        lockfile
    end

    def handle_svn_commit(repo)
        repos, local_wc, owner, password, email, encpass, commit_msg = nil
        File.readlines("data/monitored_svn_repos.txt").each do |line|
            if line =~ /^#{repo}/
                puts2 "line == #{line}, repo=#{repo}"
                repos, local_wc, owner, email, encpass = line.chomp.split("\t")
                password = decrypt(encpass)
            end
        end
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
        lockfile = get_lock_file_name(repos)
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
                res = system2(password, "git svn rebase --username #{owner}", true)
                if res.last =~ /^Current branch local-hedgehog is up to date\./
                    puts2 "Nothing to do, exiting...."
                    return
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
        gitfilename = "data/monitored_svn_repos.txt"
        return false unless File.file? gitfilename
        gitfile = File.open(gitfilename)
        gitlines = gitfile.readlines
        gitfile.close

        for line in gitlines
            return true if line =~ /^#{params[:githuburl]}/
        end

        svnfilename = "data/monitored_svn_repos.txt"
        return false unless File.file? svnfilename
        svnfile = File.open(svnfilename)
        svnlines = svnfile.readlines
        svnfile.close

        for line in svnlines
            return true if line =~ /^#{params[:rootdir]}#{params[:svndir]}/
        end
        false
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

get '/' do
    haml :index
end

get '/login' do
    haml :login
end

post '/login' do
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
        end
        redirect url('/')
    else
        session[:message] = "Username or Password incorrect"
        redirect url('/')
    end
end


get '/logout' do
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

    unless params.nil? or params.is_a? Hash or params.has_key? :payload
        return "malformed push payload"
    end
    push = params[:payload]
    log = open("data/gitpushes.log", "a")
    log.puts push
    log.close
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

get '/svn-commit-hook' do
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
    haml :newproject
end

post '/newproject' do
    protected!
    puts2 "in post handler for newproject"
    dupe_repo = dupe_repo?(params)
    if dupe_repo
        puts2 "dupe_repo is TRUE!!!!"
        haml :newproject_post, :locals => {:dupe_repo => true, :collab_ok => true}
    else
        puts2 "dupe_repo is FALSE!!!"
        # do stuff
        githuburl = params[:githuburl].sub(/\/$/, "")
        segs = githuburl.split("/")
        gitprojname = segs.pop
        githubuser = segs.pop
        svndir = params[:svndir]
        rootdir = params[:rootdir]
        conflict = params[:conflict]

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
            lockfile = get_lock_file_name(svndir)
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
                        res = system2(session[:password],
                            "git svn fetch --username #{session[:username]} hedgehog -r HEAD",
                            true)
                        puts2 "res:"
                        pp2 res
                        # see http://stackoverflow.com/questions/19712735/git-svn-cannot-setup-tracking-information-starting-point-is-not-a-branch
                        #run("git checkout -b local-hedgehog -t hedgehog")
                        run("git checkout hedgehog")
                        run("git checkout -b local-hedgehog")
                        # adding these two (would not be necessary in older git)
                        run("git config --add branch.local-hedgehog.remote .")
                        run("git config --add branch.local-hedgehog.merge refs/remotes/hedgehog")
                        # need password here?
                        run("git svn rebase --username #{session[:username]} hedgehog")

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
                            res = system2(session[:password],
                                "git svn dcommit --no-rebase --add-author-from --username #{session[:username]}",
                                true)
                        end


                        # after merging...
                        if (branchtogoto == "local-hedgehog")
                            run("git checkout master")
                        end






                    end
                end
            }

            gitfilename = "data/monitored_git_repos.txt"
            FileUtils.touch gitfilename unless File.file? gitfilename
            gitfile = File.open(gitfilename, "a")
            gitfile.puts "#{params[:githuburl]}\t#{gitprojname}\t#{session[:username]}\t#{params[:email]}\t#{encrypt(session[:password])}"
            gitfile.close
            svnfilename = "data/monitored_svn_repos.txt"
            FileUtils.touch svnfilename unless File.file? svnfilename
            svnfile = File.open(svnfilename, "a")
            svnfile.puts "#{rootdir}#{svndir}\t#{gitprojname}\t#{session[:username]}\t#{params[:email]}\t#{encrypt(session[:password])}".gsub(/^#{SVN_URL}/, "")
            svnfile.close

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
            #FIXME run cache_credentials here
            # FIXME need to git commit before git svn dcommit?
            run("git svn dcommit") # ???
        end
    end
    session[:message] = "Changes merged successfully."
    redirect url('/')    
end

