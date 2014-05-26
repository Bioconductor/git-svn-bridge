require 'rubygems'    
require 'sinatra'
require 'haml'

require_relative './core'

include GSBCore

ENV['RUNNING_SINATRA'] = "true" if `hostname` =~ /^ip/

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
            GSBCore.puts2 "alert: request.env['HTTP_HOST'] was nil..."
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
        redirect url "/"

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
    raw = request.env["rack.input"].read
    GSBCore.puts2 "request.ip is #{request.ip}"
    GSBCore.puts2 "here goes:"
    GSBCore.puts2 raw
    # DON'T specify usessl! here!
    # make sure the request comes from one of these IP addresses:
    # 204.232.175.64/27, 192.30.252.0/22. (or is us, testing)
    unless request.ip =~ 
        /^204\.232\.175|^192\.30\.252|^140\.107|23\.23\.227\.214|^127\.0\.0\.1$/
        GSBCore.puts2 "/git-push-hook: got a request from an invalid ip (#{request.ip})"
        return "You don't look like github to me."
    end
    GSBCore.puts2 "!!!!"
    GSBCore.puts2 "in /git-push-hook!!!!"
    GSBCore.puts2 "!!!!"


    push = nil


    begin
        push = JSON.parse(params[:payload])
    rescue
        begin
            push = JSON.parse(raw)
        rescue
            msg = "malformed push payload"
            GSBCore.puts2 msg
            return msg
        end
    end

    begin
        return GSBCore.handle_git_push(push)
    rescue Exception => ex
        msg = "handle_git_push failed, message was: #{ex.message}"
        GSBCore.puts2 msg
        GSBCore.puts2 ex.backtrace
        return(msg)
    end
    return "ok"
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
        GSBCore.puts2 "/svn-commit-hook: got a request from an invalid ip (#{request.ip})"
        return "You don't look like a hedgehog to me."
    end
    GSBCore.puts2 "in svn-commit-hook handler"
    repos = params[:repos]
    rev = params[:rev]
    if (request.ip != "127.0.0.1") and 
      (repos != "/extra/svndata/gentleman/svnroot/bioconductor")
        return "not monitoring this repo"
    end
    affected_repos =
      GSBCore.get_monitored_svn_repos_affected_by_commit(rev, repos)
    for repo in affected_repos
        svn_repo, local_wc = repo.split("\t")
        GSBCore.puts2 "got a commit to the repo #{svn_repo}, local wc #{local_wc}"
        GSBCore.handle_svn_commit(svn_repo)
    end
    "received!" 
end

get '/newproject' do
    protected!
    usessl!
    is_testing = request.ip == "127.0.0.1"
    haml :newproject, :locals => {:is_testing => is_testing}
end




post '/newproject' do
    protected!
    usessl!

    unless SVN_ROOTS.include? params[:rootdir]
        return haml :newproject_post, :locals => {:invalid_svn_root => true}
    end

    githuburl = params[:githuburl].rts
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
            return haml :newproject_post, :locals => {
                :no_master_branch_in_non_empty_git_repo => true,
                :message => "Non-empty Git repository must have a master branch!"}
        elsif ex.message =~ /^filename_case_conflict/
            return haml :newproject_post, :local_wc => {
                :filename_case_conflict => true,
                :badfile => ex.message.sub(":filename_case_conflict: ", "")
            }
        else
            GSBCore.puts2 "other error message: #{ex.message}"
            return haml :newproject_post, :locals => {:other_error => true}
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
    local_wc = GSBCore.get_db().get_first_row(query, params[:bridge_id]).first
    GSBCore.delete_bridge(local_wc)
    haml :delete_bridge
end

