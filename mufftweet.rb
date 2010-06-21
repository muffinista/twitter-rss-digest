#!/usr/bin/env ruby
require 'rubygems'

$KCODE = "U"

require 'sinatra'
require 'dm-core'
require 'twitter_oauth'
require 'twitter-text'
require 'builder'
require 'json'
require 'md5'

configure do
  set :sessions, true
  @@config = YAML.load_file("config.yml") rescue nil || {}
  DataMapper.setup(:default, @@config['db_url'])
end


class User
  include DataMapper::Resource

  has n, :searches

  property :id, Serial
  property :token, String
  property :secret, String
  property :created_at, DateTime
  property :updated_at, DateTime

  def url_hash
    MD5.new(secret).to_s
  end

  def url_base
    "#{id}/#{url_hash}"
  end

  def url
    "#{id}/#{url_hash}/all.xml"
  end

end
 
class Search
  include DataMapper::Resource

  belongs_to :user
  has n, :search_data

  property :id, Serial
  property :name, String
  property :type, String
  property :refresh_rate, Integer, :default => 3600*1  # default to six hours for now
  property :created_at, DateTime
  property :updated_at, DateTime
  property :refreshed_at, DateTime


  def url
    "/#{user.url_base}/#{id}.xml"
  end

  def client
    @_client ||= TwitterOAuth::Client.new(
                                          :consumer_key => ENV['CONSUMER_KEY'] || @@config['consumer_key'],
                                          :consumer_secret => ENV['CONSUMER_SECRET'] || @@config['consumer_secret'],
                                          :token => @user.nil? ? nil : @user.token,
                                          :secret => @user.nil? ? nil : @user.secret
                                          )
  end


  def refresh
    # dont refresh too often
    puts "#{id} #{refreshed_at} > #{Time.now() - refresh_rate}"
    if refreshed_at > Time.now() - refresh_rate
      return false
    end

    data = {}

    tweets = case type
             when "search" : client.search(name)
             when "mentions" : client.search("@#{name}")
             when "replies" : client.search("to:#{name}")
             when "tweets" : client.search("from:#{name}")
             end

    tweets["results"].each do |t|
      tmpdate = Date.parse(t['created_at'])
      data[tmpdate] ||= []
      data[tmpdate] << t
    end

    data.each do |date, tweets|
      tmp = search_data.first({ :tweet_date => date })
      if tmp == nil
        tmp = search_data.create({
                                   :created_at => Time.now,
                                   :updated_at => Time.now,
                                   :tweet_date => date,
                                   :data => tweets.to_json
                                 })
      else
        tmp.update({
                     :data => tweets.to_json
                   })
      end
    end

    update(
           :refreshed_at => Time.now
           )
    true
  end
end

class SearchData
  include DataMapper::Resource
  belongs_to :search

  property :id, Serial
  property :data, Text
  property :tweet_date, Date
  property :created_at, DateTime
  property :updated_at, DateTime
end

# Automatically create the tables if they don't exist
DataMapper.auto_upgrade!

enable :sessions, :logging, :dump_errors

include Twitter::Autolink



before do
  if session[:id]
    @user = User.get(session[:id])
    @has_user = (@user != nil)
  else
    @has_user = false
  end

  #
  # regexps for linkify
  #
  @generic_URL_regexp = Regexp.new( '(^|[\n ])([\w]+?://[\w]+[^ \"\n\r\t<]*)', Regexp::MULTILINE | Regexp::IGNORECASE )
  @starts_with_www_regexp = Regexp.new( '(^|[\n ])((www)\.[^ \"\t\n\r<]*)', Regexp::MULTILINE | Regexp::IGNORECASE )
  @starts_with_ftp_regexp = Regexp.new( '(^|[\n ])((ftp)\.[^ \"\t\n\r<]*)', Regexp::MULTILINE | Regexp::IGNORECASE )
  @email_regexp = Regexp.new( '(^|[\n ])([a-z0-9&\-_\.]+?)@([\w\-]+\.([\w\-\.]+\.)*[\w]+)', Regexp::IGNORECASE )

  
  @client = TwitterOAuth::Client.new(
                                     :consumer_key => ENV['CONSUMER_KEY'] || @@config['consumer_key'],
                                     :consumer_secret => ENV['CONSUMER_SECRET'] || @@config['consumer_secret'],
                                     :token => @user.nil? ? nil : @user.token,
                                     :secret => @user.nil? ? nil : @user.secret
                                     )
  @rate_limit_status = @client.rate_limit_status
end

get '/' do
  redirect '/dashboard' if @has_user == true
  erb :about
end

get '/about' do
  erb :about
end

get '/code' do
  erb :code
end

get '/dashboard/?:id?' do
  redirect '/' if @has_user == false
  @searches = @user.searches

  if params[:id]
    @search = @searches.get(params[:id])  
  end

  erb :dashboard
end


get '/:user_id/:hash/:id.xml' do
  content_type 'application/xml', :charset => 'utf-8'

  @user = User.get(params[:user_id])

  if @user.nil? or params[:hash] != @user.url_hash
    throw :halt, [404, "Not found"]
  end

  if params[:id] == "all"
    @searches = @user.searches
    title = "Whale Pail RSS Feed"
    description = "Whale Pail RSS Feed"
    link = "#{@@config['base_url']}#{@user.url}"
  else
    @searches = [@user.searches.get(params[:id])]
    title = "#{@searches.first.type} for #{@searches.first.name}"
    description = "#{@searches.first.type} for #{@searches.first.name}"
    link = "#{@@config['base_url']}#{@searches.first.url}"
  end

  builder do |xml|
    xml.instruct! :xml, :version => '1.0'
#    xml.instruct! 'xml-stylesheet', {
#      :href=>'http://feeds.feedburner.com/~d/styles/itemcontent.css',
#      :type=>'text/css',
#      :media => 'screen'
#    }



    xml.rss :version => "2.0" do
      xml.channel do
        xml.title title
        xml.description description
        xml.link link
        
        @searches.each do |s|
          s.refresh
          s.search_data.all(:order => [:tweet_date.desc]).each do |data|
            summary = ""
            JSON.parse(data.data).each do |tweet|
              tmpdate = Time.parse(tweet['created_at'])
              
              tweet_summary = "#{tmpdate.strftime('%I:%M %p')}"
              if s.type != "tweets"
                tweet_summary << " @#{tweet['from_user']}"
              end
              tweet_summary << ": #{linkify(tweet['text'])} (<a href='http://twitter.com/#{tweet['from_user']}/status/#{tweet['id']}' target='_new'>view</a>)"
              tweet_summary = auto_link(tweet_summary)
              
              summary << "<li>#{tweet_summary}</li>" # #{tweet.to_json}
            end


            xml.item do
              xml.title "#{s.type} for #{s.name}: #{data.tweet_date}"
              xml.link "#{@@config['base_url']}#{s.url}"
              xml.description "<ul>#{summary}</ul><!-- #{data.data} -->"
              xml.pubDate Time.parse(data.updated_at.to_s).rfc822
              xml.guid "#{@@config['base_url']}#{s.url}/#{data.id}"
            end
          end
        end
      end
    end
  end
end

post '/create' do
  @user.searches.create({
                          :created_at => Time.now,
                          :updated_at => Time.now
                        }.merge(params)
                        )
  redirect '/dashboard'
end

post '/update' do
  @search = @user.searches.get(params[:id]).update({
                          :updated_at => Time.now
                        }.merge(params)
                        )
  redirect '/dashboard'
end

get '/delete/:id' do
  begin
    @user.searches.get(params[:id]).destroy!
  rescue
  end
  redirect '/dashboard'
end


# store the request tokens and send to Twitter
get '/connect' do
  request_token = @client.request_token(
    :oauth_callback => ENV['CALLBACK_URL'] || @@config['callback_url']
  )
  session[:request_token] = request_token.token
  session[:request_token_secret] = request_token.secret
  redirect request_token.authorize_url.gsub('authorize', 'authenticate') 
end

# auth URL is called by twitter after the user has accepted the application
# this is configured on the Twitter application settings page
get '/auth' do
  # Exchange the request token for an access token.
  
  begin
    @access_token = @client.authorize(
                                      session[:request_token],
                                      session[:request_token_secret],
                                      :oauth_verifier => params[:oauth_verifier]
                                      )
  rescue OAuth::Unauthorized
  end

  session[:request_token] = nil
  session[:request_token_secret] = nil
  
  if @client.authorized?
      # Storing the access tokens so we don't have to go back to Twitter again
      # in this session.  In a larger app you would probably persist these details somewhere.

    @user = User.first({
                        :token => @access_token.token,
                        :secret => @access_token.secret
                       })

    if @user == nil
      @user = User.create(
                          :token => @access_token.token,
                          :secret => @access_token.secret,
                          :created_at => Time.now,
                          :updated_at => Time.now
                          )
    end

#    session[:access_token] = @access_token.token
#    session[:secret_token] = @access_token.secret
#    session[:user] = true
    session[:id] = @user.id
    
    redirect '/dashboard'
  else
    redirect '/'
  end
end

get '/disconnect' do
  session[:id] = nil
  session[:request_token] = nil
  session[:request_token_secret] = nil
  session[:access_token] = nil
  session[:secret_token] = nil
  redirect '/'
end


#
# 
#
helpers do 
  def partial(name, options={})
    erb("_#{name.to_s}".to_sym, options.merge(:layout => false))
  end

  def linkify( text )
    s = text.to_s
    s.gsub!( @generic_URL_regexp, '\1<a href="\2">\2</a>' )
    s.gsub!( @starts_with_www_regexp, '\1<a href="http://\2">\2</a>' )
    s.gsub!( @starts_with_ftp_regexp, '\1<a href="ftp://\2">\2</a>' )
    s.gsub!( @email_regexp, '\1<a href="mailto:\2@\3">\2@\3</a>' )
    s
  end
end



