#!/usr/bin/env ruby

require 'rubygems'    
require 'mechanize'
require 'crypt/gost'
require 'base64'
require 'sqlite3'
require 'net/http'

if ARGV.empty?
    puts "please supply a directory name"
    exit
end

arg = ARGV.first

DB_FILE = "/home/ubuntu/app/data/gitsvn.sqlite3"

db = SQLite3::Database.new DB_FILE


def hashify(res)
    columns = res.first 
    values = res.last

    h = {}

    columns.each_with_index do |col, i|
        h[col] = values[i]
    end
    h
end

res = db.execute2("select * from bridges where local_wc = ?", arg)
bridge = hashify(res)

res = db.execute2("select * from users where rowid = ?", bridge["user_id"])
user = hashify(res)

f = File.open("/home/ubuntu/app/etc/key")
key = f.readlines.first.chomp
f.close
$gost = Crypt::Gost.new(key)
decoded = Base64.decode64(user["encpass"])
pw = $gost.decrypt_string(decoded)

tmp = bridge["svn_repos"].split('/')
svndir = tmp.pop
rootdir = tmp.join("/") + "/"

## TODO DELETE sql record and remove directory



a = Mechanize.new

a.get('https://gitsvn.bioconductor.org/') do |page|
  # Click the login link
  login_page = a.click(page.link_with(:text => /Log In/))

  # Submit the login form
  my_page = login_page.form_with(:action => '/login') do |f|
    f.form_loginname  = user[:svn_username]
    f.form_pw         = pw
  end.click_button

  np_page = a.click(my_page.link_with(:text => /Create New Github-SVN mapping/))
  np2_page = np_page.form_with(:action => '/newproject')   do |f|
    f.form.rootdir = rootdir
    f.form.svndir = svndir
    f.form.githuburl = bridge["github_url"]
    f.form.email = user["email"]
    f.form.conflict = "git-wins" #?
    f.form.certify1 = 'true'
    f.form.certify2 = 'true'
  end
end