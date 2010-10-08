#!/usr/bin/env ruby

require 'rubygems'
require 'mufftweet'

sql = "SELECT id FROM searches WHERE refreshed_at IS NULL OR DATE_ADD(refreshed_at, INTERVAL refresh_rate SECOND) < NOW()"
#sql = "select id from searches where refreshed_at < date('now', '1 hour')"

searches = repository(:default).adapter.select(sql).each do |id|
  #puts "update feed #{id}"
  search = Search.get(id)
  search.refresh
end
