# frozen_string_literal: true
require 'net/pop'
require 'test/unit'
require 'digest/md5'
require 'base64'

class TestPOP < Test::Unit::TestCase
  def setup
    @users = {'user' => 'pass' }
    @ok_user = 'user'
    @stamp_base = "#{$$}.#{Time.now.to_i}@localhost"
    # base64 of a dummy xoauth2 token
    @md5_oauth2 = 'dXNlcj1tYWlsQG1haWwuY29tAWF1dGg9QmVhcmVyIHJhbmRvbXRva2VuAQE='
  end

  def test_pop_auth_ok
    pop_test(false, false) do |pop|
      assert_equal pop.apop?, false
      assert_equal pop.oauth2?, false
      assert_nothing_raised do
        pop.start(@ok_user, @users[@ok_user])
      end
    end
  end

  def test_pop_auth_ng
    pop_test(false) do |pop|
      assert_equal pop.apop?, false
      assert_equal pop.oauth2?, false
      assert_raise Net::POPAuthenticationError do
        pop.start(@ok_user, 'bad password')
      end
    end
  end

  def test_apop_ok
    pop_test(@stamp_base, false) do |pop|
      assert_equal pop.apop?, true
      assert_nothing_raised do
        pop.start(@ok_user, @users[@ok_user])
      end
    end
  end

  def test_apop_ng
    pop_test(@stamp_base, false) do |pop|
      assert_equal pop.apop?, true
      assert_raise Net::POPAuthenticationError do
        pop.start(@ok_user, 'bad password')
      end
    end
  end

  def test_apop_invalid
    pop_test("\x80"+@stamp_base, false) do |pop|
      assert_equal pop.apop?, true
      assert_raise Net::POPAuthenticationError do
        pop.start(@ok_user, @users[@ok_user])
      end
    end
  end

  def test_apop_invalid_at
    pop_test(@stamp_base.sub('@', '.'), false) do |pop|
      assert_equal pop.apop?, true
      assert_raise Net::POPAuthenticationError do
        pop.start(@ok_user, @users[@ok_user])
      end
    end
  end

  def test_oauth2
    pop_test(false, true) do |pop|
      assert_equal pop.oauth2?, true
      assert_nothing_raised do
        pop.start('mail@mail.com', 'randomtoken')
      end
    end
  end

  def test_oauth2_invalid
    pop_test(false, true) do |pop|
      assert_equal pop.oauth2?, true
      assert_raise Net::POPAuthenticationError do
        pop.start('mail@mail.com', 'wrongtoken')
      end
    end
  end


  def test_popmail
    # totally not representative of real messages, but
    # enough to test frozen bugs
    lines = [ "[ruby-core:85210]" , "[Bug #14416]" ].freeze
    command = Object.new
    command.instance_variable_set(:@lines, lines)

    def command.retr(n)
      @lines.each { |l| yield "#{l}\r\n" }
    end

    def command.top(number, nl)
      @lines.each do |l|
        yield "#{l}\r\n"
        break if (nl -= 1) <= 0
      end
    end

    net_pop = :unused
    popmail = Net::POPMail.new(1, 123, net_pop, command)
    res = popmail.pop
    assert_equal "[ruby-core:85210]\r\n[Bug #14416]\r\n", res
    assert_not_predicate res, :frozen?

    res = popmail.top(1)
    assert_equal "[ruby-core:85210]\r\n", res
    assert_not_predicate res, :frozen?
  end

  def pop_test(apop=false, oauth2=false)
    host = 'localhost'
    server = TCPServer.new(host, 0)
    port = server.addr[1]
    server_thread = Thread.start do
      sock = server.accept
      begin
        pop_server_loop(sock, apop, oauth2)
      ensure
        sock.close
      end
    end
    client_thread = Thread.start do
      begin
        begin
          pop = Net::POP3.new(host, port, apop, oauth2)
          #pop.set_debug_output $stderr
          yield pop
        ensure
          begin
            pop.finish
          rescue IOError
            raise unless $!.message == "POP session not yet started"
          end
        end
      ensure
        server.close
      end
    end
    assert_join_threads([client_thread, server_thread])
  end

  def pop_server_loop(sock, apop, oauth2)
    oauth2_auth_started = false

    if apop
      sock.print "+OK ready <#{apop}>\r\n"
    else
      sock.print "+OK ready\r\n"
    end
    user = nil
    while line = sock.gets
      if oauth2_auth_started
        if line.chop == @md5_oauth2
            sock.print "+OK\r\n"
        else
          sock.print "-ERR Authentication failure: unknown user name or bad password.\r\n"
        end

        oauth2_auth_started = false
        next
      end

      case line
      when /^USER (.+)\r\n/
        user = $1
        if @users.key?(user)
          sock.print "+OK\r\n"
        else
          sock.print "-ERR unknown user\r\n"
        end
      when /^PASS (.+)\r\n/
        if @users[user] == $1
          sock.print "+OK\r\n"
        else
          sock.print "-ERR invalid password\r\n"
        end
      when /^APOP (.+) (.+)\r\n/
        user = $1
        if apop && Digest::MD5.hexdigest("<#{apop}>#{@users[user]}") == $2
          sock.print "+OK\r\n"
        else
          sock.print "-ERR authentication failed\r\n"
        end
      when /^QUIT/
        sock.print "+OK bye\r\n"
        return
      when /^AUTH XOAUTH2\r\n/
        if not oauth2
          sock.print "+ERR command not recognized\r\n"
          return
        end

        sock.print "+\r\n"
        oauth2_auth_started = true
      else
        printf line
        sock.print "-ERR command not recognized\r\n"
        return
      end
    end
  end
end
