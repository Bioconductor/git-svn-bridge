#!/usr/bin/env ruby
require 'sqlite3'
require 'yaml'
require './core'
include GSBCore

ENV['SKIP_SANITY_CHECKS'] = 'true'

@me = ENV['USER']

bakdb = SQLite3::Database.new "/Users/#{@me}/dev/build/bioc-git-svn/app/data/gitsvn.sqlite3.bak"

bridges = bakdb.execute2("select * from bridges")
@columns = bridges.shift

REMOTE_SVN_REPO = "https://hedgehog.fhcrc.org/bioconductor"
LOCAL_SVN_REPO = "file:///Users/#{@me}/dev/build/bioc-git-svn/ext/copy-of-prod-repo"
LOCAL_SVN_WC = "/Users/#{@me}/dev/build/bioc-git-svn/ext/cpr_svn"
CANONICAL_GIT_REPOS="/Users/#{@me}/dev/build/bioc-git-svn/ext/canonical-git-repos"
@config = YAML.load_file("#{APP_ROOT}/etc/config.yml")

GSBCore.login(@config["test_username"], @config["test_password"])
@userid = GSBCore.get_user_id @config["test_username"]

def hashify(row)
    h = {}
    @columns.each_with_index do |colname, i|
        h[colname.to_sym] = row[i]
    end
    h
end


for bridge in bridges
    h = hashify(bridge)
    next if h[:svn_repos] =~ /RELEASE_2_13/
    next if h[:github_url] =~ /ChemmineOB-release/

    next if h[:svn_repos] =~ /Sushi/ # filename case conflict

    new_svn_repos = h[:svn_repos].sub REMOTE_SVN_REPO, LOCAL_SVN_REPO
    segs = h[:github_url].split("/")
    user = segs[segs.length-2]
    new_github_url = h[:github_url].sub("https://github.com", "file://#{CANONICAL_GIT_REPOS}") + ".git"
    if user == @me # or use String#index
        new_github_url = new_github_url.sub user, "IWASUSER"
        new_github_url = new_github_url.sub "/#{user}/", "/"
        new_github_url = new_github_url.sub "IWASUSER", user

    else
        new_github_url = new_github_url.sub "/#{user}/", "/"
    end
    puts "changing #{h[:svn_repos]} to #{new_svn_repos}"
    puts "changing #{h[:github_url]} to #{new_github_url}"
    puts

    conflict = "git-wins"
    res = GSBCore.new_bridge(new_github_url, new_svn_repos, conflict, @config["test_username"],
        @config["test_password"], @config["test_email"])
    puts res

    # Dir.chdir LOCAL_SVN_WC do
    #     segs = h[:local_wc].split("_")
    #     pkg = segs.pop 
    #     relurl = segs.join("/").sub("2/14", "2_14").sub("RELEASE/2", "RELEASE_2")
    #     Dir.chdir relurl do 
    #         puts "exporting #{h[:svn_repos]}"
    #         next if File.exists? pkg
    #         `svn export #{h[:svn_repos]}`
    #     end
    # end
    # Dir.chdir CANONICAL_GIT_REPOS do
    #     gitssh = h[:github_url].sub("https://github.com/", "git@github.com:") + ".git"
    #     dirname = gitssh.split("/").last
    #     puts "cloning #{dirname}"
    #     next if File.exists? dirname
    #     `git clone --bare #{gitssh}`
    # end
end