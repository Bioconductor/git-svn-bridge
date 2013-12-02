require 'rubygems'
require 'sinatra'
if `hostname` =~ /^ip-/
    require '/home/ubuntu/app/app.rb'
else
    require 'app'
end


set :environment, ENV['RACK_ENV'].to_sym
set :app_file,     'app.rb'
disable :run

log = File.new("logs/sinatra.log", "a")
#STDOUT.reopen(log)
$stderr.reopen(log)
$stderr.sync = true

run Sinatra::Application