require 'socket'
require 'thread'

require_relative 'song'
require_relative 'parser'

# todo: get idle to work
#
# todo: command list as a do block
# mpd.command_list do
#   volume 10
#   play xyz
# end


# error codes in ack.h
# valid tags in tag.h
# tags = {:artist, :artistsort, :album, :albumartist, :albumartistsort,
#  :title, :track, :name, :genre, :date, :composer, :performer, :comment, :disk,
#  :musicbrainz_artistid, :musicbrainz_albumid, :musicbrainz_albumartist_id, :musicbrainz_trackid
# }

# TODO:
# 0.15 - added range support
# * commands:
#  - "playlistinfo" supports a range now
#  - added "sticker database", command "sticker", which allows clients
#     to implement features like "song rating"
# * protocol:
#  - added the "findadd" command
#  - allow changing replay gain mode on-the-fly
#  - omitting the range end is possible

# ver 0.17 (2012/06/27)
# * protocol:
#  - support client-to-client communication
#  - new commands "searchadd", "searchaddpl"

# @!macro [new] error_raise
#   @raise (see #send_command)
# @!macro [new] returnraise
#   @return [Boolean] returns true if successful.
#   @macro error_raise


class MPD

  # Standard MPD error.
  class MPDError < StandardError; end

  include Parser

  # The version of the MPD protocol the server is using.
  attr_reader :version
 
  # Initialize an MPD object with the specified hostname and port.
  # When called without arguments, 'localhost' and 6600 are used.
  def initialize(hostname = 'localhost', port = 6600)
    @hostname = hostname
    @port = port
    @socket = nil
    @version = nil
    @stop_cb_thread = false
    @mutex = Mutex.new
    @cb_thread = nil
    @callbacks = {}
  end

  # This will register a block callback that will trigger whenever
  # that  specific event happens.
  #
  #   mpd.on :volume do |volume|
  #     puts "Volume was set to #{volume}"!
  #   end
  #
  # One can also define separate methods or Procs and whatnot,
  # just pass them in as a parameter.
  #
  #  method = Proc.new {|volume| puts "Volume was set to #{volume}"! }
  #  mpd.on :volume, &method
  #
  def on(event, &block)
    @callbacks[event] ||= []
    @callbacks[event].push block
  end

  # Triggers an event, running it's callbacks.
  # @param [Symbol] event The event that happened.
  def emit(event, *args)
    p "#{event} was triggered!"
    @callbacks[event] ||= []
    @callbacks[event].each do |cb|
      cb.call *args
    end
  end

  # Connect to the daemon.
  #
  # When called without any arguments, this will just connect to the server
  # and wait for your commands.
  #
  # When called with true as an argument, this will enable callbacks by starting
  # a seperate polling thread, which will also automatically reconnect if disconnected 
  # for whatever reason.
  #
  # @return [true] Successfully connected.
  # @raise [MPDError] If connect is called on an already connected instance.
  def connect(callbacks = false)
    raise MPDError, 'Already Connected!' if self.connected?

    @socket = File.exists?(@hostname) ? UNIXSocket.new(@hostname) : TCPSocket.new(@hostname, @port)
    @version = @socket.gets.chomp.gsub('OK MPD ', '') # Read the version

    if callbacks and (@cb_thread.nil? or !@cb_thread.alive?)
      @stop_cb_thread = false
      @cb_thread = Thread.new(self) { |mpd|
        old_status = {}
        connected = ''
        while !@stop_cb_thread
          status = mpd.status rescue {}
          c = mpd.connected?

          # @todo Move into status?
          if connected != c
            connected = c
            emit(:connection, connected)
          end

          status[:time] = [nil, nil] if !status[:time] # elapsed, total
          status[:audio] = [nil, nil, nil] if !status[:audio] # samp, bits, chans

          status.each do |key, val|
            next if val == old_status[key] # skip unchanged keys

            if key == :song
              emit(:song, mpd.current_song)
            else # convert arrays to splat arguments
              val.is_a?(Array) ? emit(key, *val) : emit(key, val) 
            end
          end
          
          old_status = status
          sleep 0.1

          if !connected
            sleep 2
            unless @stop_cb_thread
              mpd.connect rescue nil
            end
          end
        end
      }
    end

    return true
  end

  # Check if the client is connected
  #
  # @return [Boolean] True only if the server responds otherwise false.
  def connected?
    return false if !@socket

    ret = send_command(:ping) rescue false
    return ret
  end

  # Disconnect from the server. This has no effect if the client is not
  # connected. Reconnect using the {#connect} method. This will also stop the
  # callback thread, thus disabling callbacks
  def disconnect
    @stop_cb_thread = true

    return if @socket.nil?

    @socket.puts 'close'
    @socket.close
    @socket = nil
  end

  # Waits until there is a noteworthy change in one or more of MPD's subsystems. 
  # As soon as there is one, it lists all changed systems in a line in the format 
  # 'changed: SUBSYSTEM', where SUBSYSTEM is one of the following:
  #
  # * *database*: the song database has been modified after update.
  # * *update*: a database update has started or finished. If the database was modified 
  #   during the update, the database event is also emitted.
  # * *stored_playlist*: a stored playlist has been modified, renamed, created or deleted
  # * *playlist*: the current playlist has been modified
  # * *player*: the player has been started, stopped or seeked
  # * *mixer*: the volume has been changed
  # * *output*: an audio output has been enabled or disabled
  # * *options*: options like repeat, random, crossfade, replay gain
  # * *sticker*: the sticker database has been modified.
  # * *subscription*: a client has subscribed or unsubscribed to a channel
  # * *message*: a message was received on a channel this client is subscribed to; this 
  #   event is only emitted when the queue is empty
  #
  # If the optional +masks+ argument is used, MPD will only send notifications 
  # when something changed in one of the specified subsytems.
  #
  # @since MPD 0.14
  # @param [Symbol] masks A list of subsystems we want to be notified on.
  def idle(*masks)
    send_command(:idle, *masks)
  end 

  # Returns the config of MPD (currently only music_directory).
  # Only works if connected trough an UNIX domain socket.
  # @return [Hash] Configuration of MPD
  def config
    send_command :config
  end

  # Add the file _path_ to the playlist. If path is a directory, 
  # it will be added *recursively*.
  # @macro returnraise
  def add(path)
    send_command :add, path
  end

  # Adds a song to the playlist (*non-recursive*) and returns the song id.
  # Optionally, one can specify the position on which to add the song (since MPD 0.14).
  def addid(path, pos=nil)
    send_command :addid, pos
  end

  # Clears the current playlist.
  # @macro returnraise
  def clear
    send_command :clear
  end

  # Clears the current error message reported in status
  # (also accomplished by any command that starts playback).
  #
  # @macro returnraise
  def clearerror
    send_command :clearerror
  end

  # Set the crossfade between songs in seconds.
  # @macro returnraise
  def crossfade=(seconds)
    send_command :crossfade, seconds
  end

  # @return [Integer] Crossfade in seconds.
  def crossfade
    return status[:xfade]
  end

  # Get the currently playing song
  #
  # @return [MPD::Song]
  def current_song
    Song.new send_command :currentsong
  end

  # Deletes the song from the playlist.
  #
  # Since MPD 0.15 a range can also be passed.
  # @param [Integer] pos Song with position in the playlist will be deleted.
  # @param [Range] pos Songs with positions within range will be deleted.
  # @macro returnraise
  def delete(pos)
    send_command :delete, pos
  end

  # Delete the song with the +songid+ from the playlist.
  # @macro returnraise
  def deleteid(songid)
    send_command :deleteid, songid
  end

  # Counts the number of songs and their total playtime
  # in the db matching, matching the searched tag exactly.
  # @return [Hash] a hash with +songs+ and +playtime+ keys.
  def count(type, what)
    send_command :count, type, what
  end

  # Finds songs in the database that are EXACTLY
  # matched by the what argument. type should be
  # 'album', 'artist', or 'title'
  # 
  # @return [Array<MPD::Song>] Songs that matched.
  def find(type, what)
    build_songs_list send_command(:find, type, what)
  end

  # Kills the MPD process.
  # @macro returnraise
  def kill
    send_command :kill
  end

  # Lists all of the albums in the database.
  # The optional argument is for specifying an artist to list 
  # the albums for
  #
  # @return [Array<String>] An array of album names.
  def albums(artist = nil)
    list :album, artist
  end

  # Lists all of the artists in the database.
  #
  # @return [Array<String>] An array of artist names.
  def artists
    list :artist
  end

  # This is used by the albums and artists methods
  # type should be 'album' or 'artist'. If type is 'album'
  # then arg can be a specific artist to list the albums for
  #
  # type can be any MPD type
  #
  # @return [Array<String>]
  def list(type, arg = nil)
    send_command :list, type, arg
  end

  # List all of the directories in the database, starting at path.
  # If path isn't specified, the root of the database is used
  #
  # @return [Array<String>] Array of directory names
  def directories(path = nil)
    response = send_command :listall, path
    filter_response response, :directory
  end

  # List all of the files in the database, starting at path.
  # If path isn't specified, the root of the database is used
  #
  # @return [Array<String>] Array of file names
  def files(path = nil)
    response = send_command(:listall, path)
    filter_response response, :file
  end

  # List all of the playlists in the database
  # 
  # @return [Array<Hash>] Array of playlists
  def playlists
    send_command :listplaylists
  end

  # List all of the songs in the database starting at path.
  # If path isn't specified, the root of the database is used
  #
  # @return [Array<MPD::Song>]
  def songs(path = nil)
    build_songs_list send_command(:listallinfo, path)
  end

  # List all of the songs by an artist
  #
  # @return [Array<MPD::Song>]
  def songs_by_artist(artist)
    find :artist, artist
  end

  # Loads the playlist name.m3u (do not pass the m3u extension
  # when calling) from the playlist directory. Use `playlists`
  # to what playlists are available
  #
  # Since 0.17, a range can be passed to load, to load only a
  # part of the playlist.
  # 
  # @macro returnraise
  def load(name, range=nil)
    send_command :load, name, range
  end

  # Move the song at `from` to `to` in the playlist.
  # Since 0.15, +from+ can be a range of songs to move.
  # @macro returnraise
  def move(from, to)
    send_command :move, from, to
  end

  # Move the song with the `songid` to `to` in the playlist.
  # @macro returnraise
  def moveid(songid, to)
    send_command :moveid, songid, to
  end

  # Plays the next song in the playlist.
  # @macro returnraise
  def next
    send_command :next
  end

  # Resume/pause playback.
  # @macro returnraise
  def pause=(toggle)
    send_command :pause, toggle
  end

  # Is MPD paused?
  # @return [Boolean]
  def paused?
    return status[:state] == :pause
  end

  # Used for authentication with the server
  # @param [String] pass Plaintext password
  def password(pass)
    send_command :password, pass
  end

  # Ping the server.
  # @macro returnraise
  def ping
    send_command :ping
  end

  # Begin playing the playist.   
  # @param [Integer] pos Position in the playlist to start playing.
  # @macro returnraise
  def play(pos = nil)
    send_command :play, pos
  end

  # Is MPD playing?
  # @return [Boolean]
  def playing?
    return status[:state] == :play
  end

  # Begin playing the playlist.
  # @param [Integer] songid ID of the song where to start playing.
  # @macro returnraise
  def playid(songid = nil)
    send_command :playid, songid
  end

  # @return [Integer] Current playlist version number.
  def playlist_version
    status[:playlist]
  end

  # List the current playlist.
  # This is the same as playlistinfo without args.
  #
  # @return [Array<MPD::Song>] Array of songs in the playlist.
  def playlist
    build_songs_list send_command(:playlistinfo)
  end

  # Returns the song at the position +pos+ in the playlist,
  # @return [MPD::Song]
  def song_at_pos(pos)
    Song.new send_command(:playlistinfo, pos)
  end

  # Returns the song with the +songid+ in the playlist,
  # @return [MPD::Song]
  def song_with_id(songid)
    Song.new send_command(:playlistid, songid)
  end

  # List the changes since the specified version in the playlist.
  # @return [Array<MPD::Song>]
  def playlist_changes(version)
    build_songs_list send_command(:plchanges, version)
  end

  # Plays the previous song in the playlist.
  # @macro returnraise
  def previous
    send_command :previous
  end

  # Enable/disable consume mode.
  # @since MPD 0.16
  # When consume is activated, each song played is removed from playlist 
  # after playing.
  # @macro returnraise
  def consume=(toggle)
    send_command :consume, toggle
  end

  # Returns true if consume is enabled.
  def consume?
    return status[:consume]
  end

  # Enable/disable single mode.
  # @since MPD 0.15
  # When single is activated, playback is stopped after current song,
  # or song is repeated if the 'repeat' mode is enabled.
  # @macro returnraise
  def single=(toggle)
    send_command :single, toggle
  end

  # Returns true if single is enabled.
  def single?
    return status[:single]
  end

  # Enable/disable random playback.
  # @macro returnraise
  def random=(toggle)
    send_command :random, toggle
  end

  # Returns true if random playback is currently enabled,
  def random?
    return status[:random]
  end

  # Enable/disable repeat mode.
  # @macro returnraise
  def repeat=(toggle)
    send_command :repeat, toggle
  end

  # Returns true if repeat is enabled,
  def repeat?
    return status[:repeat]
  end

  # Removes (*PERMANENTLY!*) the playlist +playlist.m3u+ from
  # the playlist directory
  # @macro returnraise
  def rm(playlist)
    send_command :rm, playlist
  end

  alias :remove_playlist :rm

  # Saves the current playlist to `playlist`.m3u in the
  # playlist directory.
  # @macro returnraise
  def save(playlist)
    send_command :save, playlist
  end

  # Searches for any song that contains `what` in the `type` field
  # `type` can be 'title', 'artist', 'album' or 'filename'
  # `type`can also be 'any'
  # Searches are *NOT* case sensitive.
  #
  # @return [Array<MPD::Song>] Songs that matched.
  def search(type, what)
    build_songs_list(send_command(:search, type, what))
  end

  # Seeks to the position in seconds within the current song.
  # If prefixed by '+' or '-', then the time is relative to the current
  # playing position.
  #
  # @since MPD 0.17
  # @param [Integer, String] time Position within the current song.
  # Returns true if successful,
  def seek(time)
    send_command :seekcur, time
  end

  # Seeks to the position +time+ (in seconds) of the
  # song at +pos+ in the playlist.
  # @macro returnraise
  def seekpos(pos, time)
    send_command :seek, pos, time
  end

  # Seeks to the position +time+ (in seconds) of the song with
  # the id of +songid+.
  # @macro returnraise
  def seekid(songid, time)
    send_command :seekid, songid, time
  end

  # Sets the volume level. (Maps to MPD's +setvol+)
  # @param [Integer] vol Volume level between 0 and 100.
  # @macro returnraise
  def volume=(vol)
    send_command :setvol, vol
  end

  # Gets the volume level.
  # @return [Integer]
  def volume
    return status[:volume]
  end

  # Shuffles the playlist.
  # @macro returnraise
  def shuffle
    send_command :shuffle
  end

  # @return [Hash] MPD statistics.
  def stats
    send_command :stats
  end

  # @return [Hash] Current MPD status.
  def status
    send_command :status
  end

  # Stop playing music.
  # @macro returnraise
  def stop
    send_command :stop
  end

  # @return [Boolean] Is MPD stopped?
  def stopped?
    return status[:state] == :stop
  end

  # Swaps the song at position `posA` with the song
  # as position `posB` in the playlist.
  # @macro returnraise
  def swap(posA, posB)
    send_command :swap, posA, posB
  end

  # Swaps the positions of the song with the id `songidA`
  # with the song with the id `songidB`.
  # @macro returnraise
  def swapid(songidA, songidB)
    send_command :swapid, songidA, songidB
  end

  # Tell the server to update the database. Optionally,
  # specify the path to update.
  #
  # @return [Integer] Update job ID
  def update(path = nil)
    send_command :update, path
  end

  # Same as {#update}, but also rescans unmodified files.
  #
  # @return [Integer] Update job ID
  def rescan(path = nil)
    send_command :rescan, path
  end

  # Gives a list of all outputs
  # @return [Array<Hash>] An array of outputs.
  def outputs
    send_command :outputs
  end

  # Enables specified output.
  # @param [Integer] num Number of the output to enable.
  # @macro returnraise
  def enableoutput(num)
    send_command :enableoutput, num
  end

  # Disables specified output.
  # @param [Integer] num Number of the output to disable.
  # @macro returnraise
  def disableoutput(num)
    send_command :disableoutput, num
  end

  private # Private Methods below

  # Used to send a command to the server. This synchronizes
  # on a mutex to be thread safe
  #
  # @return (see #handle_server_response)
  # @raise [MPDError] if the command failed.
  def send_command(command, *args)
    raise MPDError, "Not Connected to the Server" if @socket.nil?

    @mutex.synchronize do
      begin
        @socket.puts convert_command(command, *args)
        return handle_server_response
      rescue Errno::EPIPE
        @socket = nil
        raise MPDError, 'Broken Pipe (Disconnected)'
      end
    end
  end

  # Handles the server's response (called inside {#send_command}).
  # Repeatedly reads the server's response from the socket and
  # processes the output.
  #
  # @return (see Parser#build_response)
  # @return [true] If "OK" is returned.
  # @raise [MPDError] If an "ACK" is returned.
  def handle_server_response
    return if @socket.nil?

    msg = ''
    reading = true
    error = nil
    while reading
      line = @socket.gets
      case line
      when "OK\n", nil
        reading = false
      when /^ACK/
        error = line
        reading = false
      else
        msg += line
      end
    end

    if !error
      return true if msg.empty?
      return build_response(msg)
    else
      err = error.match(/^ACK \[(?<code>\d+)\@(?<pos>\d+)\] \{(?<command>.*)\} (?<message>.+)$/)
      raise MPDError, "#{err[:code]}: #{err[:command]}: #{err[:message]}"
    end
  end

  # This filters each line from the server to return
  # only those matching the regexp. The regexp is removed
  # from the line before it is added to an Array
  #
  # This is used in the `directories` and `files` methods
  # to return only the directory/file names
  # @note Broken.
  def filter_response(string, filter)
    regexp = Regexp.new("\A#{filter}: ", Regexp::IGNORECASE)
    list = []
    string.split("\n").each do |line|
      if line =~ regexp
        list << line.gsub(regexp, '')
      end
    end

    return list
  end

end
