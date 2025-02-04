#
# Matter_UDPServer.be - implements IPv6 UDP communication for Matter
#
# Copyright (C) 2023  Stephan Hadinger & Theo Arends
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

# Matter_UDPServer class
#
# For receiving and outgoing messages on UDP
#

import matter

#@ solidify:Matter_UDPPacket_sent,weak
#@ solidify:Matter_UDPServer,weak

#################################################################################
# Matter_UDPPacket_sent class
#
# A packet that needs to be resent if not acknowledged by the other party
#################################################################################
class Matter_UDPPacket_sent
  var raw                         # bytes() to be sent
  var addr                        # ip_address (string)
  var port                        # port (int)
  var msg_id                      # (int) message identifier that needs to be acknowledged, or `nil` if no ack needed
  var session_id                  # (int) exchange id, for logging only
  var retries                     # 0 in first attempts, goes up to RETRIES
  var next_try                    # timestamp (millis) when to try again

  def init(raw, addr, port, id, session_id)
    self.raw = raw
    self.addr = addr
    self.port = port
    self.msg_id = id
    self.retries = 0
    self.session_id = (session_id != nil) ? session_id : 0
    self.next_try = tasmota.millis() + matter.UDPServer._backoff_time(self.retries)
  end

  #############################################################
  # Send packet now.
  #
  # Returns `true` if packet was successfully sent.
  def send(udp_socket)
    import string
    var ok = udp_socket.send(self.addr ? self.addr : udp_socket.remote_ip, self.port ? self.port : udp_socket.remote_port, self.raw)
    if ok
      tasmota.log(string.format("MTR: sending packet to '[%s]:%i'", self.addr, self.port), 4)
    else
      tasmota.log(string.format("MTR: error sending packet to '[%s]:%i'", self.addr, self.port), 3)
    end
    return ok
  end

end
matter.UDPPacket_sent = Matter_UDPPacket_sent

#################################################################################
# Matter_UDPServer class
#
#################################################################################
class Matter_UDPServer
  static var RETRIES = 6            # 7 transmissions max (6 retries) - 2 more than spec `MRP_MAX_TRANSMISSIONS` 4.11.8 p.146
  static var MAX_PACKETS_READ = 4   # read at most 4 packets per tick
  var addr, port                    # local addr and port
  var listening                     # true if active
  var udp_socket
  var dispatch_cb                   # callback to call when a message is received
  var packets_sent                  # list map of packets sent to be acknowledged

  #############################################################
  # Init UDP Server listening to `addr` and `port` (opt).
  #
  # By default, the server listens to `""` (all addresses) and port `5540`
  def init(addr, port)
    self.addr = addr ? addr : ""
    self.port = port ? port : 5540
    self.listening = false
    self.packets_sent = []
  end

  #############################################################
  # Starts the server.
  # Registers as device handler to Tasmota
  #
  # `cb(packet, from_addr, from_port)`: callback to call when a message is received.
  # Raises an exception if something is wrong.
  def start(cb)
    if !self.listening
      self.udp_socket = udp()
      var ok = self.udp_socket.begin(self.addr, self.port)
      if !ok    raise "network_error", "could not open UDP server" end
      self.listening = true
      self.dispatch_cb = cb
      tasmota.add_driver(self)
    end
  end

  #############################################################
  # Stops the server and remove driver
  def stop()
    if self.listening
      self.udp_socket.stop()
      self.listening = false
      tasmota.remove_driver(self)
    end
  end

  #############################################################
  # At every tick:
  # Check if a packet has arrived, and dispatch to `cb`.
  # Read at most `MAX_PACKETS_READ (4) packets at each tick to
  # avoid any starvation.
  # Then resend queued outgoing packets.
  def every_50ms()
    import string
    var packet_read = 0
    if self.udp_socket == nil  return end
    var packet = self.udp_socket.read()
    while packet != nil
      # self.packet = packet
      packet_read += 1
      var from_addr = self.udp_socket.remote_ip
      var from_port = self.udp_socket.remote_port
      tasmota.log(string.format("MTR: UDP received from [%s]:%i", from_addr, from_port), 3)
      if self.dispatch_cb
        self.dispatch_cb(packet, from_addr, from_port)
      end
      # are we reading new packets?
      if packet_read < self.MAX_PACKETS_READ
        packet = self.udp_socket.read()
      else
        packet = nil
      end
    end
    self._resend_packets()               # resend any packet
  end

  #############################################################
  # Resend packets if they have not been acknowledged by receiver
  # either with direct Ack packet or ack embedded in another packet.
  # Packets with `id`=`nil` are not resent.
  # <BR>
  # Packets are re-sent at most `RETRIES` (4) times, i.e. sent maximum 5 times.
  # Exponential backoff is added after each resending.
  # <BR>
  # If all retries expired, remove packet and log.
  def _resend_packets()
    var idx = 0
    while idx < size(self.packets_sent)
      var packet = self.packets_sent[idx]
      if tasmota.time_reached(packet.next_try)
        if packet.retries <= self.RETRIES
          tasmota.log("MTR: .          Resending packet id=" + str(packet.msg_id), 3)
          packet.send(self.udp_socket)         # resend
          packet.next_try = tasmota.millis() + self._backoff_time(packet.retries)
          packet.retries += 1
          idx += 1
        else
          import string
          self.packets_sent.remove(idx)
          tasmota.log(string.format("MTR: .          (%6i) Unacked packet '[%s]:%i' msg_id=%i", packet.session_id, packet.addr, packet.port, packet.msg_id), 2)
        end
      else
        idx += 1
      end
    end
  end

  #############################################################
  # Just received acknowledgment, remove packet from sender
  def received_ack(id)
    if id == nil   return end
    tasmota.log("MTR: receveived ACK id="+str(id), 3)
    var idx = 0
    while idx < size(self.packets_sent)
      if self.packets_sent[idx].msg_id == id
        self.packets_sent.remove(idx)
        tasmota.log("MTR: .          Removed packet from sending list id=" + str(id), 3)
      else
        idx += 1
      end
    end
  end

  #############################################################
  # Send a packet, enqueue it if `id` is not `nil`
  def send_response(raw, addr, port, id, session_id)
    var packet = matter.UDPPacket_sent(raw, addr, port, id, session_id)
    packet.send(self.udp_socket)    # send
    if id
      # tasmota.log("MTR: <<< enqueue id="+str(id))
      self.packets_sent.push(packet)
    end
  end

  #############################################################
  # placeholder, nothing to run for now
  def every_second()
  end

  #############################################################
  # Compute exponential backoff as per 4.11.2.1 p.137
  static def _backoff_time(n)
    def power_int(v, n)
      var r = 1
      while n > 0
        r *= v
        n -= 1
      end
      return r
    end

    import math
    var i = 300                                   # SLEEPY_ACTIVE_INTERVAL
    var rand = real(math.rand() & 0xFF) / 255     # 0..1 with reasonable granularity
    var n_power = n > 0 ? n - 1 : 0
    var mrpBackoffTime = i * power_int(1.6, n_power) * (1.0 + rand * 0.25 )
    return int(mrpBackoffTime)
  end
end
matter.UDPServer = Matter_UDPServer
