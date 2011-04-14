#!/usr/bin/env ruby

#
# simple script to convert from old SearchData to new Tweet storage. yay!
#

$KCODE = "UTF8"

require "rubygems"
require 'bundler'
Bundler.require

require 'mufftweet'

# keep sinatra from booting
set :run, false

class SearchData
  include DataMapper::Resource

  storage_names[:default] = "search_datum"

  property :id, Serial
  property :search_id, Integer
  property :data, Text
  property :tweet_date, Date
  property :created_at, DateTime
  property :updated_at, DateTime
end

#mysql> desc search_datum;
#+------------+------------------+------+-----+---------+----------------+
#| Field      | Type             | Null | Key | Default | Extra          |
#+------------+------------------+------+-----+---------+----------------+
#| id         | int(10) unsigned | NO   | PRI | NULL    | auto_increment |
#| data       | text             | YES  |     | NULL    |                |
#| tweet_date | date             | YES  |     | NULL    |                |
#| created_at | datetime         | YES  |     | NULL    |                |
#| updated_at | datetime         | YES  |     | NULL    |                |
#| search_id  | int(10) unsigned | NO   | MUL | NULL    |                |
#+------------+------------------+------+-----+---------+----------------+


Search.all.each do |s|
  puts "import for #{s.id}"
  SearchData.all(:search_id => s.id).each do |sd|
    tweets = JSON.parse(sd.data)
    puts "#{s.id} #{sd.created_at} #{tweets.size}"
    tweets.each do |tweet|
      s.create_tweet(tweet)
    end
  end
end
