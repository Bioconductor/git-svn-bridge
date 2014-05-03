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


HOSTNAME=`hostname`
if HOSTNAME =~ /^dhcp/
    APP_ROOT="#{ENV['HOME']}/dev/build/bioc-git-svn/app"
else
    APP_ROOT="#{ENV['HOME']}/app"
end

DB_FILE = "#{APP_ROOT}/data/gitsvn.sqlite3"


module GSBCore

    def GSBCore.puts2(arg)
        puts(arg)
        STDOUT.flush
        if (ENV["RUNNING_SINATRA"] == "true")
            STDERR.puts(arg) unless HOSTNAME =~ /^dhcp/
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


    def GSBCore.create_new_project()
    end

    def GSBCore.handle_svn_commit()
    end

    def GSBCore.handle_git_push()
        # make a note of most recent commit 
        # pull (only master if possible)
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
                res = run("svn delete #{item}")
                unless succcess(res)
                    raise "Failed to svn delete #{item}!"
                end
            end
        end

        adds = diff[:to_be_copied] + diff[:to_be_added]

        for item in adds
            # copy

            if File.directory? "#{src}/#{item}"
                FileUtils.mkdir "#{dest}/#{item}"
            else
                FileUtils.cp "#{src}/#{item}", "#{dest}/#{item}"
            end

            if dest_vcs == "git"
                Dir.chdir dest do
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