#!/usr/bin/env ruby

require 'dcf'
require 'pp'

def add_url_to_description(url, descriptionfile)
    txt = File.readlines(descriptionfile).join
    dcf = Dcf.parse txt
    if dcf.nil?
        puts("oops, Dcf.parse returned nil")
        return
    end
    if dcf.length > 1
        puts("oops, more than one dcf record in this file!")
        return
    end
    pp dcf
    # lines = File.readlines(descriptionfile)
    # lines = lines.collect {|i| i.chomp}
    # lines = lines.reject {|i| i.empty?}
    # nonurllines = []
    # url = ""
    # urlmode = false
    # for line in lines
    #     if line =~ /^URL:/
    #         urlmode = true
    #         url = line
    #         next
    #     end
    #     else
    #         if urlmode
    #             puts "urlmode is true, line is #{line}"
    #             if line =~ /^\s/
    #             else
    #                 urlmode = false
    #             end
    #             urlmode = false unless line =~ /^\s/
    #             url += "\n#{line}" if urlmode
    #         end
    #     end
    # end
    # url.sub!(/^URL:\s*/, "")
    # puts "is url empty? #{url.empty?}"
    # puts "url=\n#{url}"
end

##### 

descfile=<<"EOT"
Foo: bar
Baz: bunk
URL:http://1
   http://2
   http://3
lab: butt
EOT

f = File.open("/tmp/DESCRIPTION", "w")
f.write(descfile)
f.close


add_url_to_description("https://github.com/dtenenbaum/gitsvntest0", "/tmp/DESCRIPTION")

