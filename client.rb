#!/usr/bin/env ruby

require 'rubygems'
require 'eventmachine'
require 'json'
require 'ncurses'

ClientConfig = {
  :port => 6789,
  :ip => ARGV[0] || '0.0.0.0'
}

module Ncurses
  KEY_DELETE = ?\C-h
end

module JsChat
  class Protocol
    def legal_commands
      %w(message joined quit error join names)
    end

    def legal?(command)
      legal_commands.include? command
    end

    def message(json)
      "#{Time.now.strftime('%H:%M')} [#{json['room']}] <#{json['user']}> #{json['message']}"
    end

    def join(json)
      "* User #{json['user']} joined #{json['room']}"
    end

    def quit(json)
      "* User #{json['user']} left #{json['room']}"
    end
    
    def names(json)
      "* In this channel: #{json.join(', ')}"
    end

    def error(json)
      "* [ERROR] #{json['message']}"
    end
  end
end

module JsClient
  def keyboard=(keyboard)
    @keyboard = keyboard
  end

  module KeyboardInput
    def setup_screen
      Ncurses.initscr
      @windows = {}
      
      Ncurses.raw
      Ncurses.start_color
      Ncurses.noecho
      Ncurses.init_pair 1, Ncurses::COLOR_WHITE, Ncurses::COLOR_BLACK
      Ncurses.init_pair 2, Ncurses::COLOR_WHITE, Ncurses::COLOR_BLUE

      setup_windows
    end

    def setup_windows
      Ncurses.refresh

      display_windows
      
      Signal.trap('SIGWINCH') do
        resize
      end
    end

    def display_windows
      rows, cols = get_window_size
      @windows[:text] = Ncurses.newwin(rows - 2, cols, 0, 0)
      @windows[:info] = Ncurses.newwin(rows - 1, cols, rows - 2, 0)
      @windows[:input] = Ncurses.newwin(rows, cols, rows - 1, 0)
      @windows[:text].bkgd Ncurses.COLOR_PAIR(1)
      @windows[:text].scrollok(true)
      @windows[:info].bkgd Ncurses.COLOR_PAIR(2)
      @windows[:info].addstr "[Time] \n"
      @windows[:input].bkgd Ncurses.COLOR_PAIR(1)
      @windows[:input].keypad(true)
      @windows[:input].nodelay(true)

      @windows[:text].refresh
      @windows[:info].refresh
      @windows[:input].refresh

      @input_field = Ncurses::Form::FIELD.new(1, Ncurses.COLS - 10, 0, 10, 0, 0)
      @input_field.set_max_field(140)
      @input_form = Ncurses::Form::FORM.new([@input_field])
      @input_form.set_form_win @windows[:input]
      @input_form.post_form
      @input_field.set_field_buffer 0, ''

      Ncurses.init_pair 1, Ncurses::COLOR_WHITE, Ncurses::COLOR_BLACK
      Ncurses.init_pair 2, Ncurses::COLOR_WHITE, Ncurses::COLOR_BLUE

      @windows[:input].mvprintw(0, 0, "[channel] ")
      @windows[:input].refresh
    end

    def resize
      Ncurses.refresh
    end

    # FIXME: This doesn't work after resize
    # I've tried other ruby ncurses programs and they don't either
    def get_window_size
      Ncurses.refresh
      cols, rows = [], []
      Ncurses.stdscr.getmaxyx rows, cols
      [rows.first, cols.first]
    end

    def receive_data(data)
      @clipboard ||= ''
      c = data[0]

      case c
        when -1
        # Return
        when Ncurses::KEY_ENTER, ?\n, ?\r
          @input_form.form_driver Ncurses::Form::REQ_BEG_LINE
          line = @input_field.field_buffer(0)
          line.strip!

          unless line.empty? and line.length > 0
            manage_commands line
          end
          @input_form.form_driver Ncurses::Form::REQ_CLR_FIELD
        # Backspace
        when Ncurses::KEY_BACKSPACE, ?\C-h, 127
          @input_form.form_driver Ncurses::Form::REQ_DEL_PREV
          @input_form.form_driver Ncurses::Form::REQ_CLR_EOL
        when ?\C-d
          @input_form.form_driver Ncurses::Form::REQ_DEL_CHAR
        when Ncurses::KEY_LEFT, ?\C-b
          @input_form.form_driver Ncurses::Form::REQ_PREV_CHAR
        when Ncurses::KEY_RIGHT, ?\C-f
          @input_form.form_driver Ncurses::Form::REQ_NEXT_CHAR
        when ?\C-a
          @input_form.form_driver Ncurses::Form::REQ_BEG_LINE
        when ?\C-e
          @input_form.form_driver Ncurses::Form::REQ_END_LINE
        when ?\C-k
          @input_form.form_driver Ncurses::Form::REQ_CLR_EOL
        when ?\C-u
          @input_form.form_driver Ncurses::Form::REQ_BEG_LINE
          @clipboard = @input_field.field_buffer(0)
          @input_form.form_driver Ncurses::Form::REQ_CLR_FIELD
        when ?\C-y
          unless @clipboard.empty?
            cursor_position = Ncurses.getcurx(@windows[:input])
            
            text = @input_field.field_buffer(0).insert(cursor_position - 9, @clipboard)
            @input_field.set_field_buffer(0, text)
            
            @windows[:text].addstr "#{cursor_position}\n #{text}"
            @windows[:text].refresh
          end
        when ?\C-c
          quit
        when ?\C-w
          @input_form.form_driver Ncurses::Form::REQ_PREV_CHAR
          @input_form.form_driver Ncurses::Form::REQ_DEL_WORD
        else
          @input_form.form_driver c
      end
      @windows[:input].refresh
    end

    def show_message(message)
      @windows[:text].addstr "#{message}\n"
      @windows[:text].refresh
      @windows[:input].refresh
    end

    def quit
      Ncurses.endwin
      exit
    end

    def manage_commands(line)
      operand = strip_command line
      case line
        when %r{/nick}
          @connection.send_identify operand
        when %r{/quit}
          quit
        when %r{/names}
          @connection.send_names operand
        when %r{/join}, %r{/j}
          @connection.send_join operand
        else
          @connection.send_message(line)
      end
    end

    def strip_command(line)
      matches = line.match(%r{/[a-zA-Z][^ ]*(.*)})
      if matches
        matches[1].strip
      else
        line
      end
    end

    def connection=(connection)
      @connection = connection
    end
  end

  def receive_data(data)
    json = JSON.parse(data)

    # Execute the json
    if json.has_key?('display') and @protocol.legal? json['display']
      @keyboard.show_message @protocol.send(json['display'], json[json['display']])
    else
      @keyboard.show_message "* [SERVER] #{data}"
    end
  end

  def send_join(channel)
    @current_channel = channel
    send_data({ 'join' => channel }.to_json)
  end

  def send_names(channel = nil)
    channel = @current_channel if channel.nil? or channel.strip.empty?
    send_data({ 'names' => channel }.to_json)
  end

  def send_message(line)
    send_data({ 'to' => @current_channel, 'send' => line }.to_json + "\n")
  end

  def send_identify(username)
    send_data({ 'identify' => username }.to_json + "\n")
  end

  def unbind
    Ncurses.endwin
    Ncurses.clear
    puts "Disconnected from server"
    exit
  end

  def post_init
    # When connected
    @protocol = JsChat::Protocol.new
    send_identify ENV['LOGNAME']
  end
end

EM.run do
  puts "Connecting to: #{ClientConfig[:ip]}"
  connection = EM.connect ClientConfig[:ip], ClientConfig[:port], JsClient

  EM.open_keyboard(JsClient::KeyboardInput) do |keyboard|
    keyboard.connection = connection
    keyboard.setup_screen
    connection.keyboard = keyboard
  end
end