require_relative './core'
include GSBCore
require 'open3'
require 'pp'
bl = BridgeList.new

basedir = "#{ENV['HOME']}/biocsync"

@to_email = "dtenenba@fhcrc.org"
@to_name = "Dan Tenenbaum"
@from_email = "biocbuild@fhrc.org"
@from_name = "Git SVN Bridge"



def send_email(subject, msg)
    message = <<"MESSAGE_END"
From: #{@from_name} <#{@from_email}>
To: #{@to_name} <#{@to_email}>
Subject: #{subject}

#{msg}
MESSAGE_END
    
    Net::SMTP.start('mx.fhcrc.org') do |smtp|
      smtp.send_message message, @from_email, 
                                 @to_email
    end
end

def notify_sync_failure(svn_repos)

    subject = "sync failure, both repos need updates"
    message = <<"MESSAGE_END"
This repos needs updates from both git and svn:
#{svn_repos}
MESSAGE_END

    send_email(subject, message)    
end

def notify_general_failure(ex)
    subject = "sync script exception"
    message = <<"MESSAGE_END"
Failure of sync_repos.rb:
#{ex.message}
#{ex.backtrace.join "\n"}
MESSAGE_END
    send_email("sync_repos exception", message)
end


begin

    bl.each do |bridge|
        git_needs_update = false
        svn_needs_update = false
        svn_remote_head = nil
        user = GSBCore.get_user_record_from_id(bridge[:user_id])
        owner = user.first
        pw = GSBCore.decrypt user.last
        Dir.chdir "#{basedir}/git/#{bridge[:local_wc]}" do
            Open3.popen3 "git checkout master"
            git_local_head = `git rev-parse HEAD`.strip
            git_remote_heads = 
                `git ls-remote --heads #{bridge[:github_url]}`.split("\n")
            git_remote_head = nil
            begin
                git_remote_head = 
                    git_remote_heads.find{|i|i=~/refs\/heads\/master/}.split(/\s+/).first
            rescue
                puts "NO REMOTE MASTER REF FOUND FOR #{bridge[:github_url]}!!"
                # do something else? send email?
                next
            end
            unless git_local_head == git_remote_head
                puts "DIFFERENT REMOTE HEAD FOR #{bridge[:github_url]}"
                git_needs_update = true
            end
        end
        Dir.chdir "#{basedir}/svn/#{bridge[:local_wc]}" do
            svn_local_head =
              `svn info`.split("\n").
              find{|i|i=~/^Revision: /}.sub("Revision: ", "").to_i
            svn_remote_head = 
              `svn info #{bridge[:svn_repos]}`.split("\n"). 
              find{|i|i=~/^Last Changed Rev: /}.sub("Last Changed Rev: ", "").to_i
            if svn_remote_head > svn_local_head
                res = `svn st -u`
                if res.split("\n").length > 1
                    puts "NEWER REVISION IN SVN (#{svn_remote_head} vs #{svn_local_head}) for #{bridge[:svn_repos]}!"
                    svn_needs_update = true
                end
            end
        end


        if git_needs_update and svn_needs_update
            puts "BOTH GIT AND SVN NEED AN UPDATE FOR #{bridge[:svn_repos]}!"
            notify_sync_failure bridge[:svn_repos] # FIXME uncomment when ready
            next
        end
        
        if git_needs_update
            Dir.chdir "#{basedir}/git/#{bridge[:local_wc]}" do
                `git pull`
                `git checkout master`
            end
            # simulate svn commit hook
            GSBCore.handle_svn_commit bridge[:svn_repos]
        end

        if svn_needs_update
            Dir.chdir "#{basedir}/svn/#{bridge[:local_wc]}" do
                res = 
                  GSBCore.system2(pw, "svn up #{GSBCore.svnflags(owner)}")
            end
            # simulate git push hook
            push_obj = {"repository" => {"url" => bridge[:github_url]}}
            GSBCore.handle_git_push push_obj
        end


    end



rescue Exception => ex 
    notify_general_failure(ex.message)
    raise ex
end

