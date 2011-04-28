#!/usr/bin/env ruby

$KCODE = "UTF8"

require "rubygems"

require 'bundler'
Bundler.require

require 'md5'
require 'mufftweet'

# keep sinatra from booting
set :run, false

users = []

sql = "SELECT id FROM searches WHERE refreshed_at IS NULL OR DATE_ADD(refreshed_at, INTERVAL refresh_rate SECOND) < NOW()"
searches = repository(:default).adapter.select(sql).each do |id|
  puts "update feed #{id}"
  search = Search.get(id)

  dirname = "public/#{search.user.id}/#{search.user.url_hash}"
  dest = "#{dirname}/#{search.id}.xml"
  if search.refresh(true) or ! File.exist?(dest)
    puts "feed #{id} has new data, rebuild cache"

    # track users with updated feeds -- we'll update their unified feed later
    users << search.user

    fb = FeedBuilder.new
    result = fb.build(
                      :title => "#{search.type} for #{search.name}",
                      :description => "#{search.type} for #{search.name}",
                      :link => "#{@@config['base_url']}/#{search.url}",
                      :searches => [search]
                      )

    FileUtils.mkdir_p dirname
    File.open(dest, 'w') {|f| f.write(result) }
  end
end

users.uniq.each { |u|
  puts "now update full feed for #{u.id}"
  searches = u.searches
  fb = FeedBuilder.new
  result = fb.build(
                    :title => "Whale Pail RSS Feed",
                    :description => "Whale Pail RSS Feed",
                    :link => "#{@@config['base_url']}/#{u.url}",
                    :searches => searches
                    )

  dirname = "public/#{u.id}/#{u.url_hash}"
  dest = "#{dirname}/all.xml"
  
  FileUtils.mkdir_p dirname
  File.open(dest, 'w') {|f| f.write(result) }
}
