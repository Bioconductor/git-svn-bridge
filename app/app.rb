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
        commit_message = nil
        Dir.chdir("#{ENV['HOME']}/biocsync/git/#{local_wc}") do
            result = run("git pull")
            if (result.first.exitstatus == 0)
                puts2 "no problems with git pull!"
            else
                puts2 "problems with git pull, tell the user"
                # FIXME tell the user...
                return
            end
            run("git checkout master") # necessary?
            # how do we know what was committed in the last push?
            # there may have been many commits in between pushes
            # do we want all of them in order to show the svn user
            # all that has happened in git since the last push?
            # I don't know how so I'll mark this as FIXME and
            # just show the last commit for now....
            puts2("getting last git log message")
            log = `git log -1`
            lines = log.split "\n"
            msg = ""
            skip = false
            ismsg = false
            for line in lines
                if line =~ /^commit /
                    commit_id = line.sub(/^commit /, "")
                elsif line =~ /^Author:/
                    author = line.sub(/^Author: /, "")
                elsif line =~ /^Date: /
                    date = line.sub(/^Date:[ ]+/, "")
                    skip = true
                end
                if skip
                    skip = false
                    ismsg = true
                    next
                end
                if ismsg
                    msg += (line.sub(/^    /, "") + "\n")
                end
            end
            commit_message=<<"EOF"
From git commit #{commit_id} by #{author}

#{msg}

Committed to git at #{date}
EOF
        end
        Dir.chdir("#{ENV['HOME']}/biocsync") do
            #hmm, diff file has the same name whether it was generated by git
            #push or svn commit. problem? (maybe not with queues)
            puts2("run diff...")
            FileUtils.rm_rf "#{local_wc}_diff.txt"
            res = `diff -ru -x .git -x .svn svn/#{local_wc} git/#{local_wc} > #{local_wc}_diff.txt`
            puts2("does diff file exist? #{File.exist? "#{local_wc}_diff.txt"}")
            puts2("how many lines does it have? #{`wc -l #{local_wc}_diff.txt`}")
            lines = IO.readlines "#{local_wc}_diff.txt"
            for line in lines
                puts2("line in diff: #{line}")
                if line =~ /^\+\+\+ |^---/
                    puts2("run patch...")
                    res = run("patch -p0 < #{local_wc}_diff.txt") # FIXME handle errors
                    break
                end

            end
            # this doesn't work but IO.readlines (above) does. why?
            # File.readlines("#{local_wc}_diff.txt") do |line|
            #     puts2("line in diff: #{line}")
            #     if line =~ /^\+\+\+ |^---/
            #         puts2("run patch...")
            #         res = run("patch -p0 < #{local_wc}_diff.txt") # FIXME handle errors
            #         break
            #     end
            # end
            puts2("handle binary diffs...")
            handle_binary_diffs("git", local_wc)
            puts2("reconcile file differences...")
            handle_only_in("git", local_wc)
        end
        Dir.chdir("#{ENV['HOME']}/biocsync/svn/#{local_wc}") do
            result = run("svn st")
            files = result.last.split("\n")
            addme = []
            for file in files
                addme.push file.sub(/^\?[ ]+/, "") if file =~ /^\?/
            end
            # see http://stackoverflow.com/questions/1218237/subversion-add-all-unversioned-files-to-subversion-using-one-linux-command
            #run %Q(svn st |grep ^?| cut -c9-| awk '{print "\x27"$0"\x27"}' | xargs svn add)
            unless(addme.empty?)
                run("svn add #{addme.join ' '}")
            end
            unless (`svn st`.empty?)
                res = IO.popen({"SVNPASS"=>password},
                   "svn commit -F - --username #{owner} --no-auth-cache --non-interactive",
                   mode="r+") do |io|
                      io.write commit_message
                      io.close_write
                      io.read
                end
#                res = system2(password, # f1xme - commit message
#                    "svn commit -m 'a better commit message' --username #{owner} --no-auth-cache --non-interactive")
            else
                puts2 "nothing to commit"
            end
        end
        # fixme uncomment this:
        #FileUtils.rm "#{ENV['HOME']}/biocsync/#{local_wc}_diff.txt"
    end

    def get_monitored_svn_repos_affected_by_commit(rev_num)
        f = File.open("data/config")
        p = f.readlines().first().chomp

        #cmd = "svn log --username pkgbuild --non-interactive -v --xml -r " + 
        #{}"#{rev_num} --limit 1 https://hedgehog.fhcrc.org/bioconductor/"
        #puts2("before system")
        #res = system({"SVNPASS" => p},
        cmd = "svn log --xml -v --username pkgbuild --password $SVNPASS " +
          "--non-interactive --no-auth-cache " +
          "-r #{rev_num} --limit 1 https://hedgehog.fhcrc.org/bioconductor/"
        #result = `#{cmd}` 
        result = system2(p, cmd, echo=false, get_stdout=true)
        #puts2("after system")
        #result = run(cmd)
        xml_doc = Nokogiri::XML(result) #dante
        paths = xml_doc.xpath("//path")
        changed_paths = []
        for path in paths
            changed_paths.push path.children.to_s
        end
        puts2 "changed_paths:"
        pp2 changed_paths
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
        result.first.exitstatus == 0
    end

    def system2(pw, cmd, echo=false, get_stdout=false)
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
        puts2 "stdout output:\n#{stdout_str}"
        puts2 "stderr output:\n#{stderr.gets(nil)}"
        puts2 "---done---"
        if (get_stdout)
            stdout_str
        else
            result
        end
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


    def handle_binary_diffs(source, proj)
        unless ["git", "svn"].include? source
            throw "invalid source! [must be git or svn]"
        end

        Dir.chdir("#{ENV['HOME']}/biocsync") do
            difffile = "#{proj}_diff.txt"
            File.readlines(difffile).each do |line|
                line.chomp!
                if line =~ /^Binary files/ and line =~ /differ$/
                    line.gsub!(/^Binary files /, "")
                    line.gsub!(/ differ$/, "")
                    gitfile, svnfile = line.split(" and ")
                    if source == "svn"
                        FileUtils.cp svnfile, gitfile
                    else
                        FileUtils.cp gitfile, svnfile
                    end
                end
            end
        end

    end

    def handle_only_in(source, proj)
        if source == "svn"
            dest = "git"
        elsif source == "git"
            dest = "svn"
        else
            throw "invalid source! [must be git or svn]"
        end

        Dir.chdir("#{ENV['HOME']}/biocsync") do
            difffile = "#{proj}_diff.txt"
            File.readlines(difffile).each do |line|
                line.chomp!
                if line =~ /^Only in #{source}/
                    line.gsub!(/^Only in /, "")
                    segs = line.split ": "
                    file = segs.join("/")
                    file.gsub!("//", "/")
                    destfile = file.sub(/^#{source}/, dest)
                    puts2 "line == #{line}, file == #{file}, destfile == #{destfile}"
                    FileUtils.cp_r file, destfile
                end
                if line =~ /^Only in #{dest}/
                    line.gsub!(/^Only in /, "")
                    segs = line.split ": "
                    file = segs.join("/")
                    file.gsub!("//", "/")
                    # delete from source
                    Dir.chdir("#{source}/#{proj}") do
                        if source == "svn"
                            run("svn delete #{file}")
                        else
                            run("git rm #{file}")
                        end
                    end
                end
            end
        end
    end

    def handle_svn_commit(repo)
        repos, local_wc, owner, password, email, encpass, commit_message = nil
        File.readlines("data/monitored_svn_repos.txt").each do |line|
            if line =~ /^#{repo}/
                puts2 "line == #{line}, repo=#{repo}"
                repos, local_wc, owner, email, encpass = line.chomp.split("\t")
                password = decrypt(encpass)
            end
        end
        commit_message = nil
        puts2 "owner is #{owner}"
        Dir.chdir("#{ENV['HOME']}/biocsync/svn/#{local_wc}") do
            res = system2(password, "svn up --non-interactive --no-auth-cache --username #{owner}")
            res = run("svn log --limit 1 --xml --non-interactive --no-auth-cache --username #{owner}")
            xml = res.last
            doc = Nokogiri::Slop(xml)
            revision = doc.log.logentry.attributes['revision'].value
            author = doc.log.logentry.author.text
            date = doc.log.logentry.date.text
            msg = doc.log.logentry.msg.text
            commit_message = <<"EOF"
From SVN commit ##{revision} by #{author}

#{msg}

Committed to SVN at #{date}
EOF

        end
        Dir.chdir("#{ENV['HOME']}/biocsync") do
            puts2("running diff")
            res = `diff -ru -x .git -x .svn git/#{local_wc} svn/#{local_wc} > #{local_wc}_diff.txt`
            lines = IO.readlines "#{local_wc}_diff.txt"
            for line in lines
                if line =~ /^\+\+\+ |^---/
                    puts2 "running patch"
                    res = run("patch -p0 < #{local_wc}_diff.txt") # FIXME handle errors
                    break
                end
            end
            # this doesn't work but IO.readlines does:
            # File.readlines("#{local_wc}_diff.txt") do |line|
            #     if line =~ /^\+\+\+ |^---/
            #         puts2 "running patch"
            #         res = run("patch -p0 < #{local_wc}_diff.txt") # FIXME handle errors
            #         break
            #     end
            # end
            puts "handle binary diffs"
            handle_binary_diffs("svn", local_wc)
            puts "handle file addition/removal"
            handle_only_in("svn", local_wc)
        end
        Dir.chdir("#{ENV['HOME']}/biocsync/git/#{local_wc}") do
            # fixme this fails when creating bridge (but does not halt work):
            run("git checkout master") # necessary?
            files_to_add = Dir.glob(".*") + Dir.glob("*")
            files_to_add.reject! {|i| [".git", "..", "."].include? i}
            run("git add #{files_to_add.join ' '}") unless files_to_add.empty?
            # only commit if there is something to commit?
            # i think git will ignore unnecessary commits?
            res = IO.popen("git commit -a -F -", mode="r+") do |io|
                io.write commit_message
                io.close_write
                io.read
            end
            puts2("result of commit: #{res}")

            commit_id = `git rev-parse HEAD`.chomp

            #run("git commit -a -m 'make this an automated message'")
            # fixme - this command could fail and the web page would still say
            # everything worked:
            result = run("git push origin master")
            if (success(result))
                commit_ids_file = "#{APP_ROOT}/data/git_commit_ids.txt"
                FileUtils.touch(commit_ids_file)
                f = File.open(commit_ids_file, "a")
                puts2("trying to break circle on #{commit_id}")
                f.puts commit_id
            end

        end
        FileUtils.rm "#{ENV['HOME']}/biocsync/#{local_wc}_diff.txt"
    end


    def dupe_repo?(params)
        puts2 "params:"
        pp2 params
        test(?d, "#{ENV['HOME']}/biocsync/svn/#{params[:svndir]}") 
    end


    def encrypt(input)
        encrypted = $gost.encrypt_string(input)
        Base64.encode64(encrypted)
    end

    def decrypt(input)
        decoded = Base64.decode64(input)
        $gost.decrypt_string(decoded)
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


post '/echoer' do
#    require 'cgi'
    s = "\n\n\n"
    s += request.env["rack.input"].read
    s += "\n\n\n"
    puts2 s
    s
end

# simulate a call to this hook with e.g.
# curl -X POST -d @foo.json http://localhost:9393/git-push-hook
# make sure foo.json contains valid json like that sent by github
post '/git-push-hook' do
    # make sure the request comes from one of these IP addresses:
    # 204.232.175.64/27, 192.30.252.0/22. (or is us, testing)
    unless request.ip =~ /^204\.232\.175|^192\.30\.252|^140\.107|^127\.0\.0\.1$/
        puts2 "/git-push-hook: got a request from an invalid ip (#{request.ip})"
        return "You don't look like github to me."
    end

    puts2 "!!!!"
    puts2 "in /git-push-hook!!!!"
    puts2 "!!!!"
    #push = JSON.parse(params[:payload])
    push = params[:payload]

    log = open("data/gitpushes.log", "a")
    log.puts push
    log.close
    gitpush = JSON.parse(params[:payload])

    ## make sure we're not in a vicious circle...

    commits = gitpush["commits"]
    ids = commits.map {|i| i["id"]}

    # nothing has been written here yet since changing over to diffpatch:
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

    handle_git_push(gitpush) # FIXME put in queue
    "received"
end


# simulate a call to the svn commit hook with e.g.
# /svn-commit-hook?repos=/extra/svndata/gentleman/svnroot/bioconductor&rev=83823
get '/svn-commit-hook' do
    sleep 1 # give app a chance to cache the commit id
    # make sure request comes from a hutch ip
    unless request.ip  =~ /^140\.107|^127\.0\.0\.1/ #  140.107.170.120 appears to be hedgehog
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
    puts2 "affected repos:"
    pp2 affected_repos

    for repo in affected_repos
        svn_repo, local_wc = repo.split("\t")
        puts2 "got a commit to the repo #{svn_repo}, local wc #{local_wc}"
        handle_svn_commit(svn_repo) # FIXME put in queue
    end
    "received!" 
end

get '/newproject' do
    protected!
    haml :newproject
end

# FIXME: how to reconcile two repos at the start if one is not empty?
# If something is not done explicitly, then files could be deleted
# from one of the repos (which one depends on which one gets a commit/push)
# first after the bridge is created. 
# One option would be to insist that the git repo be empty and copy
# the svn contents to it at bridge creation time; (this is what we
# are doing for the moment);  another option would
# be to ask the user what strategy they want to use to reconcile the
# two repos.
post '/newproject' do
    protected!
    dupe_repo = dupe_repo?(params)
    if dupe_repo
        puts2 "dupe_repo is TRUE!!!!"
        return(haml :newproject_post, :locals => {:dupe_repo => true, :collab_ok => true})
    else
        puts2 "dupe_repo is FALSE!!!"
        # do stuff
        githuburl = params[:githuburl].sub(/\/$/, "")
        segs = githuburl.split("/")
        gitprojname = segs.pop
        githubuser = segs.pop
        svndir = params[:svndir]
        rootdir = params[:rootdir]

        # make sure it' an empty repo
        json = URI.parse("https://api.github.com/repos/#{githubuser}/#{gitprojname}").read
        obj = JSON.parse(json)
        unless (obj['size'] == 0)
            puts2 "github repos is not empty, size is #{obj[:size]}"
            return(haml :newproject_post, :locals => {:github_repos_empty => true})
        end

        full_svn_url = "#{rootdir}#{svndir.gsub("/", "")}"

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
            return(haml :newproject_post, :locals => {:dupe_repo => false, :collab_ok => false})
        else
            # fixme - make sure both repos are valid
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

            git_ssh_url = "git@github.com:#{githubuser}/#{gitprojname}.git"
            Dir.chdir("#{ENV['HOME']}/biocsync") do
                FileUtils.mkdir_p "git"
                FileUtils.mkdir_p "svn"
                Dir.chdir("git") do
                    FileUtils.rm_rf svndir
                    result = run("git clone #{git_ssh_url}")
                end
                Dir.chdir("svn") do
                    FileUtils.rm_rf svndir
                    # set svn pw in env...
                    result = system2(session[:password], 
                        "svn co --non-interactive --no-auth-cache --username #{session[:username]}  #{full_svn_url}")
                end
                # /trunk/madman/RpacksTesting/test6
                repo = full_svn_url.sub(SVN_URL, "")
                puts2 "doing initial population of git from svn, repo is #{repo}"
                Dir.chdir(APP_ROOT) do
                    handle_svn_commit(repo)
                end
            end
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

# this is deprecated/not called int he diffpatch way of doing things
# in any case, it does not deal with binary diffs
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
    # f1xme - what are the implications of ensuring the user is logged in here?
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
            #F1XME run cache_credentials here
            run("git svn dcommit") # ???
        end
    end
    session[:message] = "Changes merged successfully."
    redirect url('/')    
end

get '/fox' do
    "root dir: #{settings.root}"
end
