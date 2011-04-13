#!/usr/bin/env ruby

$KCODE = "UTF8"

require "rubygems"

require 'bundler'
Bundler.require

require 'mufftweet'

# keep sinatra from booting
set :run, false

sql = "SELECT id FROM searches WHERE refreshed_at IS NULL OR DATE_ADD(refreshed_at, INTERVAL refresh_rate SECOND) < NOW()"
searches = repository(:default).adapter.select(sql).each do |id|
  puts "update feed #{id}"
  search = Search.get(id)
  search.refresh(true)
end
