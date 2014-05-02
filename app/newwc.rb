require 'sqlite3'
require 'open3'
require 'crypt/gost'
require 'base64'
require 'pp'

@rootdir = "#{ENV['HOME']}/biocsync"
@dbfile = "#{ENV['HOME']}/app/data/gitsvn.sqlite3"
@db = SQLite3::Database.new @dbfile

def run(cmd)
    `echo ""` # needed to reset $?
    sin, sout, serr = Open3.popen3 cmd
    res = $?
    [sout.readlines.join.strip, serr.readlines.join.strip, res.to_i]
end

def system2(pw, cmd, echo=false)
    if echo
        cmd = "echo $SVNPASS | #{cmd}"
    end
    env = {"SVNPASS" => pw}
    puts "running SYSTEM command: #{cmd}"
    begin
        stdin, stdout, stderr, thr = Open3.popen3(env, cmd)
    rescue
        puts "Caught an error running system command"
    end
    result = thr.value.exitstatus
    puts "result code: #{result}"
    stdout_str = stdout.gets(nil)
    stderr_str = stderr.gets(nil)
    # FIXME - apparently not all output (stderr?) is shown when there is an error
    puts "stdout output:\n#{stdout_str}"
    puts "stderr output:\n#{stderr_str}"
    puts "---system2() done---"
    [result, stderr_str, stdout_str] #though it gets returned ok
end


def hashify(res)
    columns = res.first 
    values = res.last

    h = {}

    columns.each_with_index do |col, i|
        h[col] = values[i]
    end
    h
end



def getinfo(dir)
    res = @db.execute2("select * from bridges where local_wc = ?", dir)
    bridge = hashify(res)
    res = @db.execute2("select * from users where rowid = ?", bridge["user_id"])
    user = hashify(res)
    [bridge, user]
end

def getpw(dir)
    bridge, user = getinfo(dir)
    f = File.open("/home/ubuntu/app/etc/key")
    key = f.readlines.first.chomp
    f.close
    $gost = Crypt::Gost.new(key)
    decoded = Base64.decode64(user["encpass"])
    $gost.decrypt_string(decoded)
end


rows = @db.execute2("select * from bridges;")
columns = rows.shift

dirs = ["git", "svn"]
dirs = ["git"]

Dir.chdir "/home/ubuntu/biocsync" do
    rows.each_with_index do |row, i|
        for dir in dirs
            Dir.chdir dir do
                if dir == "git"
                    unless File.exists? row[1]
                        puts "cloning #{row[1]}..."
                        url = row[3]
                        url = url.sub(/^https:\/\/github.com\//i, "git@github.com:")
                        url = "#{url}.git"
                        run("git clone #{url} #{row[1]}")
                    end
                else
                    #puts "does #{row[1]} exist? #{File.exists? row[1]}"
                    unless File.exists? row[1]
                        bridge, user = getinfo(row[1])
                        username = user["svn_username"]
                        pw = getpw(row[1])
                        cmd = "svn checkout --username #{username} --password \"$SVNPASS\" #{row.first} #{row[1]}"
                        puts "checking out #{row[1]}..."
                        system2(pw, cmd)
                    end
                end
            end
        end
    end
nil
end

