#!/usr/bin/env ruby

$KCODE = "UTF8"

require 'rubygems'
require 'bundler'
require 'md5'

Bundler.require

set :run, false
set :environment, :production
set :views, "views"

require 'mufftweet'
run MuffTweet
