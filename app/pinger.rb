#!/usr/bin/env ruby

# This should be run as root (by cron maybe).
# It makes sure the server is up.

res = `curl -I https://gitsvn.bioconductor.org`

lines = res.split "\n"

responsecode = lines.find{|i| i =~ /^HTTP\/1\.1 /}.split(" ")[1]

unless responsecode == "200"
    `service apache2 restart`
    puts "restarted apache at `date`."
end
