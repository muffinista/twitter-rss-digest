#!/usr/bin/env ruby
$KCODE = "UTF8"

require 'rubygems'
require 'time'

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
  has n, :tweets
  
  property :id, Serial
  property :max_id, Integer, :min => -9223372036854775807, :max => 9223372036854775807
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


  def refresh(force=false)
    #
    # dont refresh too often
    #
    if force == false and refreshed_at != nil and refreshed_at > Time.now() - refresh_rate
      return false
    end
    
    params = case type
             when "search" then name
             when "mentions" then "@#{name}"
             when "replies" then "to:#{name}"
             when "tweets" then "from:#{name}"
             end

    data = client.search(params, {
                           :since_id => self.max_id.nil? ? 0 : self.max_id
                         })
    
    data["results"].each do |t|
      create_tweet(t)
    end

    self.max_id = data["max_id"]
    self.refreshed_at = Time.now
    self.save

    true
  end

  def create_tweet(t)
    id = t.has_key?("id_str") ? t["id_str"] : t["id"]
    tmp = tweets.first({ :id => id })
    if tmp.nil?
      tmpdate = Time.parse(t['created_at'])
      opts = {
        :id => id,
        :created_at => tmpdate,
        :loaded_at => Time.now,
        :data => t.to_json
      }
      [:profile_image_url, :from_user, :from_user_id, :to_user, :to_user_id,
       :text, :iso_language_code, :source].each do |key|
        opts[key] = t[key.to_s]
      end
        
      tmp = tweets.create(opts)
    end
  end

end


class Tweet
  include DataMapper::Resource
  belongs_to :search, :key => true

  property :id, Integer, :min => -9223372036854775807, :max => 9223372036854775807, :key => true
  property :profile_image_url, String, :length => 150
  property :from_user, String
  property :from_user_id, Integer, :min => -9223372036854775807, :max => 9223372036854775807  
  property :to_user, String
  property :to_user_id, Integer, :min => -9223372036854775807, :max => 9223372036854775807  

  # this is so long since any incoming ampersands/etc are escaped
  property :text, String, :length => 250
  property :iso_language_code, String, :length => 5
  property :source, String, :length => 250

  property :data, Text

  property :created_at, DateTime
  property :loaded_at, DateTime  
end

class MuffTweet < Sinatra::Base
  # globally across all models
  DataMapper::Model.raise_on_save_failure = true 
  
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
      
      @searches.each do |s|
        s.refresh
      end

      title = "Whale Pail RSS Feed"
      description = "Whale Pail RSS Feed"
      link = "#{@@config['base_url']}/#{@user.url}"
    else
      @search = @user.searches.get(params[:id])
      
      if @search.nil?
        throw :halt, [404, "Not found"]
      end
      
      @search.refresh
      @searches = [@search]
          
      title = "#{@search.type} for #{@search.name}"
      description = "#{@search.type} for #{@search.name}"
      link = "#{@@config['base_url']}/#{@search.url}"
    end

    
    builder do |xml|
      xml.instruct! :xml, :version => '1.0'
      xml.rss :version => "2.0" do
        xml.channel do
          xml.title title
          xml.description description
          xml.link link
 
          @searches.each do |search|
            # This runs a little faster since it doesn't pull all the tweets for all the searches at once
            tweets = Tweet.all(:search => search,
                               :created_at.gt => Date.today - 7,
                               :order => [:created_at.asc])
            #            tweets = search.tweets(:created_at.gt => Date.today - 7,
            #                                       :order => [:created_at.asc])
            
            add_feed_entries(xml, search, tweets)

          end
        end
      end
    end
  end

  def add_feed_entries(xml, search, tweets)
    # split tweets up by day
    search_data = tweets.group_by { |t|
      t.created_at.to_date
    }
    
    search_data.each do |date, tweets|
      summary = tweets.collect do |tweet|
        tweet_summary = auto_link([
                                   tweet.created_at.strftime('%I:%M %p'),
                                   tweet.search.type != "tweets" ? "@#{tweet.from_user}" : "",
                                   ": #{linkify(tweet.text)} (<a href='http://twitter.com/#{tweet.from_user}/status/#{tweet.id}' target='_new'>view</a>)"
                                  ].join(" "))
      end.map { |t| "<li>#{t}</li>"}
      
      xml.item do
        xml.title "#{search.type} for #{search.name}: #{date}"
        xml.link "#{@@config['base_url']}#{search.url}"
        xml.description "<ul>#{summary}</ul>"
        xml.pubDate Time.parse(tweets.last.created_at.to_s).rfc822
        xml.guid "#{@@config['base_url']}#{search.url}/#{tweets.first.id}"
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
end
