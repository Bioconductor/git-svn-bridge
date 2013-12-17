#!/usr/bin/env ruby

require 'pp'

def add_url_to_description(github_url, descriptionfile)
    lines = File.readlines(descriptionfile)
    lines = lines.collect {|i| i.chomp}
    lines = lines.reject {|i| i.empty?}
    nonurllines = []
    url = ""
    urlmode = false
    urlstartsat = nil
    urllinelength = nil
    lines.each_with_index do |line, idx|
        if line =~ /^URL:/
            urllinelength = 0
            urlstartsat = idx
            urlmode = true
            url = line
            next
        end
        if urlmode
            urlmode = false unless line =~ /^\s/
            if urlmode
                url += "\n#{line}"
                urllinelength += 1
            end
        end
    end
    url.sub!(/^URL:\s*/, "")
    if url.empty?
        nonurllines = lines
        nonurllines.push "URL: #{github_url}"
    else
        lines.each_with_index do |line, idx|
            if idx < urlstartsat || idx > (urlstartsat + urllinelength)
                nonurllines.push line
            end
        end
        url = url.gsub /\s+/, "" if url =~ /,\s/
        if url =~ /\s/
            segs = url.split(/\s+/)
        elsif url =~ /,/
            segs = url.split(",")
        else
            segs = [url]
        end
        segs.push github_url unless segs.include? github_url
        segs[0] = "URL: #{segs.first}"
        nonurllines.push segs.join " "
    end
    nonurllines = nonurllines.reject {|i| i.empty?}
    f = open(descriptionfile, "w")
    for line in nonurllines
        f.puts line
    end
    f.close
end

##### 

descfile=<<"EOT"
Foo: bar
Baz: bunk
URL: http://0 https://github.com/dtenenbaum/gitsvntest0 http://1
This:that
  cont
EOT

f = File.open("/tmp/DESCRIPTION", "w")
f.write(descfile)
f.close


add_url_to_description("https://github.com/dtenenbaum/gitsvntest0", "/tmp/DESCRIPTION")

__END__

windows line endings
no url field at all
no value for url field (but URL: is present)
url field takes up more than one line ( contains a newline)
url field already contains github url

desc file has blank lines in it