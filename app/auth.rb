#!/usr/bin/env ruby

require 'pp'
require 'net/https'
require 'uri'

$script = false

if __FILE__ == $0
    $script = true
    if ARGV.length  < 3
        puts "usage: #{$0} authfile username password [true]"
        exit
    end
    authfile = ARGV[0]
    username = ARGV[1]
    password = ARGV[2]
    return_urls = false
    return_urls = true if ARGV.length == 4 and ARGV[3] == 'true'
end



def auth(authfile, username, password, return_urls=false)
    f = File.open(authfile)
    lines = f.readlines
    f.close

    group_mode = true
    groups = []
    current_url = nil
    valid_urls = []

    for line in lines
        line.chomp!
        next if line.strip =~ /^#/
        next if line.strip.empty?
        next if line.strip =~ /\*/ # OK for now, but we might want to pay attention to this 
                                   # at some point
        if line =~ /^\[groups\]/
            group_mode = true
            next
        end
        if group_mode and line =~ /^\[/
            #pp groups
            group_mode = false
            if groups.empty?
                puts "#{username} is not in any groups" if $script
                return false
            end
        end

        if group_mode
            line.gsub!(/ /, "")
            groupname, membersraw = line.split("=")
            next if membersraw.nil?
            members = membersraw.split(",")
            groups.push groupname if members.include? username
        else
            if line.strip =~ /^\[/
                current_url = line.strip.gsub(/^\[/, "").gsub(/\]$/, "")
            elsif line.strip =~ /@/
                groupname, privs = line.gsub(/ /, "").split("=")
                groupname.gsub!(/^@/, "")
                if privs =~ /w/i
                    if groups.include? groupname
                        valid_urls.push current_url
                    end
                end
            end
        end
    end

    if valid_urls.empty?
        puts "#{username} is not in any groups with write privileges" if $script
        return false
    end

    if return_urls
        puts "returning urls:" if $script
        pp valid_urls if $script
        return valid_urls
    end

    #pp valid_urls
    url = valid_urls.first
    url += "/" unless url =~ /\/$/
    uri = URI.parse("https://hedgehog.fhcrc.org/bioconductor#{url}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    request = Net::HTTP::Get.new(uri.request_uri)
    request.basic_auth(username, password)
    response = http.request(request)

    #puts response.body

    if response.code =~ /^2/
        puts "congrats, you are valid" if $script
        return true
    else
        puts "invalid, code is #{response.code}" if $script
        return false
    end

end

if __FILE__ == $0
    auth(authfile, username, password, return_urls)
end

