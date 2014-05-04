require 'rubygems'    
require 'sinatra'
require 'haml'

require_relative './core'

include GSBCore

##require 'debugger'
# require 'pry'
# require 'crypt/gost'
# require 'base64'
# require './auth'
# require 'json'
# require 'nokogiri'
# require 'net/smtp'
# require 'open-uri'
# require 'fileutils'
# require 'tempfile'
# require 'tmpdir'
# require 'open3'
# require 'sqlite3'
# require 'net/http'


ENV['RUNNING_SINATRA'] = "true"

#use Rack::Session::Cookie, secret: 'change_me'
enable :sessions

set :default_encoding, "utf-8"
set :views, File.dirname(__FILE__) + "/views"
set :session_secret, IO.readlines("data/session_secret.txt").first


# FIXME - don't hardcode the release version here but get it from
# the config file for the BioC site. Otherwise, remember 
# to change it with each new release.

versions=`curl -s http://bioconductor.org/js/versions.js`
relLine = versions.split("\n").find{|i| i =~ /releaseVersion/}
releaseVersion = relLine.split('"')[1].sub(".", "_")

roots=<<"EOF"
https://hedgehog.fhcrc.org/bioconductor/trunk/madman/Rpacks/
https://hedgehog.fhcrc.org/bioconductor/branches/RELEASE_#{releaseVersion}/madman/Rpacks/
https://hedgehog.fhcrc.org/bioconductor/trunk/madman/workflows/
https://hedgehog.fhcrc.org/bioconductor/branches/RELEASE_#{releaseVersion}/madman/workflows/
https://hedgehog.fhcrc.org/bioconductor/trunk/madman/RpacksTesting/
https://hedgehog.fhcrc.org/bioconductor/branches/RELEASE_#{releaseVersion}/madman/RpacksTesting/
EOF
SVN_ROOTS=roots.split("\n")

DOC_URL="http://bioconductor.org/developers/how-to/git-svn/"


SVN_URL="https://hedgehog.fhcrc.org/bioconductor"

# For development, set this to /trunk/madman/RpacksTesting;
# In production, set to /trunk/madman/Rpacks.
SVN_ROOT="/trunk/madman/RpacksTesting"



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

    begin
        GSBCore.login(params['username'], params['password'])
        session[:message] = "Successful Login"
        session[:username] = params[:username]
        session[:password] = params[:password]

        if session.has_key? :redirect_url
            redirect_url = session[:redirect_url]
            session.delete :redirect_url
            redirect to redirect_url
        end

    rescue
        session[:message] = "Incorrect username/password, " + \
          "or you don't have permission to write to any SVN repositories." 
        redirect url "/"
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
    unless request.ip =~ /^204\.232\.175|^192\.30\.252|^140\.107|23\.23\.227\.214/
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



    unless params.has_key? 'payload'
        puts2 "no 'payload' key, probably a bad payload"
        return "sorry"
    end

    gitpush = JSON.parse(params["payload"])
    if gitpush.has_key? "zen"
        puts2 "responding to ping"
        return "#{obj["zen"]} Wow, that's pretty zen!"
    end


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

    unless SVN_ROOTS.include? params[:rootdir]
        return haml :newproject_post, :locals => {:invalid_svn_root => true}
    end

    githuburl = params[:githuburl].rts
    # segs = githuburl.split("/")
    # gitprojname = segs.pop
    # githubuser = segs.pop
    svndir = params[:svndir]
    rootdir = params[:rootdir]
    conflict = params[:conflict]
    email = params[:email]

    svnurl = "#{rootdir}#{svndir}"

    begin
        GSBCore.new_bridge(githuburl, svnurl, conflict,
            session[:username], session[:password], email)
        return haml :newproject_post, :locals => {:dupe_repo => false, :collab_ok => true}
    rescue Exception => ex
        if ex.message == "dupe_repo"
            return   haml :newproject_post, :locals => {:dupe_repo => true, :collab_ok => true}
        elsif ex.message == "repo_error"
            return haml :newproject_post, :locals => {:svn_repo_error => true}
        elsif ex.message == "no_write_privs"
            return haml :newproject_post, :locals => {:no_write_privs => true}
        elsif ex.message == "no_github_repo"
            return haml :newproject_post, :locals => {:invalid_github_repo => true}
        elsif ex.message == "bad_collab"
            return haml :newproject_post, :locals => {:dupe_repo => false, :collab_ok => false}
        elsif ex.message == "no_master_branch_in_non_empty_git_repo"
            return haml :newproject_post, :locals => {:no_master_branch_in_non_empty_git_repo,
                :message => "Non-empty Git repository must have a master branch!"}
        else
            return haml :newproject_post, :locals => {:other_error => true}
        end
    end
end

def post_newproject_old(params) 
    puts2 "in post handler for newproject"
    dupe_repo = dupe_repo?(params)
    if dupe_repo
        puts2 "dupe_repo is TRUE!!!!"
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


        unless SVN_ROOTS.include? rootdir
            return haml :newproject_post, :locals => {:invalid_svn_root => true}
        end

        # verify that svn repos exists and user has read permissions on it
        svnurl = "#{rootdir}#{svndir}"
        local_wc = get_wc_dirname(svnurl)
        result = system2(session[:password],
            "svn log --non-interactive --no-auth-cache --username #{session[:username]} --password \"$SVNPASS\" --limit 1 #{svnurl}")
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

            lockfile = get_lock_file_name(svnurl)
            File.open(lockfile, File::RDWR|File::CREAT, 0644) {|f|
                f.flock(File::LOCK_EX)
                Dir.chdir("#{ENV['HOME']}/biocsync") do
                    FileUtils.rm_rf local_wc # just in case
                    result = run("git clone #{git_ssh_url} #{local_wc}")
                    #res = system2(session[:password],
                    #    "svn export --non-interactive --username #{session[:username]} --password \"$SVNPASS\" #{SVN_URL}#{SVN_ROOT}/#{svndir}")
                    Dir.chdir(local_wc) do
                        filelist = run("git ls-files")
                        unless filelist.last.empty?
                            result = run("git branch -r")
                            lines = result.last.gsub(/ +/, "").split("\n")
                            unless lines.include? 'origin/master'
                                puts2 "oops, no remote master branch"
                                return(haml(:newproject_post, :locals => {:no_master => true}))
                            end
                        end
                        run("git checkout master")
                        repo_is_empty = `git branch`.empty?
                        res = system2(session[:password],
                            "svn log --non-interactive --limit 1 --username #{session[:username]} --password \"$SVNPASS\" #{rootdir}#{svndir}")

                        run("git config --add svn-remote.hedgehog.url #{rootdir}#{svndir}")
                        res = system2(session[:password],
                            "svn log --non-interactive --limit 1 --username #{session[:username]} --password \"$SVNPASS\" #{rootdir}#{svndir}")
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

                        ["master", 'local-hedgehog'].each do |branch|
                            run("git checkout #{branch}")
                            svndirs = Dir.glob(File.join('**','.svn'))
                            unless svndirs.empty?
                                puts2 "oops, collaboration is not set up properly"
                                return(haml(:newproject_post, :locals => {:svnfiles => true, :branch => branch}))
                            end
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
                local_wc, user_id, params[:githuburl].rts, timestamp)

            
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


get '/list_bridges' do
    usessl!
    query=<<-"EOT"
        select svn_repos, github_url, svn_username,
            timestamp from bridges, users
            where users.rowid = bridges.user_id
            order by datetime(timestamp) desc;
    EOT
    result = GSBCore.get_db().execute(query)
    result.each_with_index do |row, i|
        s = result[i][0]
        result[i][0] =  %Q(<a href="#{s}">#{s.sub(SVN_URL, "")}</a>) 
        g = result[i][1]
        result[i][1] = %Q(<a href="#{g}">#{g}</a>)
        t = result[i][3].to_s
        d = DateTime.strptime(t, "%Y-%m-%d %H:%M:%S.%L"  )
        result[i][3] = d.strftime "%Y-%m-%d"
    end
    haml :list_bridges, :locals => {:items => result}
end

get '/my_bridges' do
    protected!
    usessl!
    query=<<-"EOT"
        select svn_repos, github_url, 
            timestamp, bridges.rowid from bridges, users
            where users.rowid = bridges.user_id
            and bridges.user_id = ?
            order by datetime(timestamp) desc;
    EOT
    user_id = GSBCore.get_user_id(session[:username])
    result = GSBCore.get_db().execute(query, user_id)
    result.each_with_index do |row, i|
        s = result[i][0]
        result[i][0] =  %Q(<a href="#{s}">#{s.sub(SVN_URL, "")}</a>) 
        g = result[i][1]
        result[i][1] = %Q(<a href="#{g}">#{g}</a>)
        t = result[i][2].to_s
        d = DateTime.strptime(t, "%Y-%m-%d %H:%M:%S.%L"  )
        result[i][2] = d.strftime "%Y-%m-%d"
        rowid = result[i][3]
        result[i][3] = %(<a class="confirm" href="/delete_bridge?bridge_id=#{rowid}">Delete</a>)
    end
    haml :my_bridges, :locals => {:items => result}

end

get '/delete_bridge' do
    protected!
    usessl!
    query = "select local_wc from bridges where rowid = ?"
    local_wc = get_db().get_first_row(query, params[:bridge_id]).first
    dir_to_delete = "#{ENV['HOME']}/biocsync/#{local_wc}"
    res = FileUtils.rm_rf "#{ENV['HOME']}/biocsync/#{local_wc}"
    query = "delete from bridges where rowid = ?"
    get_db.execute(query, params[:bridge_id])
    haml :delete_bridge
end

