/*
 * Copyright (c) 2019 Zender & Kurtz GbR.
 *
 * Authors:
 *   Christian Pauly <krille@famedly.com>
 *   Marcel Radzio <mtrnord@famedly.com>
 *
 * This file is part of famedlysdk.
 *
 * famedlysdk is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * famedlysdk is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with famedlysdk.  If not, see <http://www.gnu.org/licenses/>.
 */

import 'dart:async';
import 'dart:convert';
import 'dart:core';

import 'package:famedlysdk/src/AccountData.dart';
import 'package:famedlysdk/src/Presence.dart';
import 'package:famedlysdk/src/RoomState.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'Client.dart';
import 'Connection.dart';
import 'Event.dart';
import 'Room.dart';
import 'User.dart';
import 'sync/EventUpdate.dart';
import 'sync/RoomUpdate.dart';
import 'sync/UserUpdate.dart';

/// Responsible to store all data persistent and to query objects from the
/// database.
class Store {
  final Client client;

  Store(this.client) {
    _init();
  }

  Database _db;

  /// SQLite database for all persistent data. It is recommended to extend this
  /// SDK instead of writing direct queries to the database.
  Database get db => _db;

  _init() async {
    var databasePath = await getDatabasesPath();
    String path = p.join(databasePath, "FluffyMatrix.db");
    _db = await openDatabase(path, version: 14,
        onCreate: (Database db, int version) async {
      await createTables(db);
    }, onUpgrade: (Database db, int oldVersion, int newVersion) async {
      if (client.debug)
        print(
            "[Store] Migrate databse from version $oldVersion to $newVersion");
      if (oldVersion != newVersion) {
        await schemes.forEach((String name, String scheme) async {
          if (name != "Clients") await db.execute("DROP TABLE IF EXISTS $name");
        });
        await createTables(db);
        await db.rawUpdate("UPDATE Clients SET prev_batch='' WHERE client=?",
            [client.clientName]);
      }
    });

    await _db.rawUpdate("UPDATE Events SET status=-1 WHERE status=0");

    List<Map> list = await _db
        .rawQuery("SELECT * FROM Clients WHERE client=?", [client.clientName]);
    if (list.length == 1) {
      var clientList = list[0];
      client.connection.connect(
        newToken: clientList["token"],
        newHomeserver: clientList["homeserver"],
        newUserID: clientList["matrix_id"],
        newDeviceID: clientList["device_id"],
        newDeviceName: clientList["device_name"],
        newLazyLoadMembers: clientList["lazy_load_members"] == 1,
        newMatrixVersions: clientList["matrix_versions"].toString().split(","),
        newPrevBatch: clientList["prev_batch"].toString().isEmpty
            ? null
            : clientList["prev_batch"],
      );
      if (client.debug)
        print("[Store] Restore client credentials of ${client.userID}");
    } else
      client.connection.onLoginStateChanged.add(LoginState.loggedOut);
  }

  Future<void> createTables(Database db) async {
    await schemes.forEach((String name, String scheme) async {
      await db.execute(scheme);
    });
  }

  Future<String> queryPrevBatch() async {
    List<Map> list = await txn.rawQuery(
        "SELECT prev_batch FROM Clients WHERE client=?", [client.clientName]);
    return list[0]["prev_batch"];
  }

  /// Will be automatically called when the client is logged in successfully.
  Future<void> storeClient() async {
    await _db
        .rawInsert('INSERT OR IGNORE INTO Clients VALUES(?,?,?,?,?,?,?,?,?)', [
      client.clientName,
      client.accessToken,
      client.homeserver,
      client.userID,
      client.deviceID,
      client.deviceName,
      client.prevBatch,
      client.matrixVersions.join(","),
      client.lazyLoadMembers,
    ]);
    return;
  }

  /// Clears all tables from the database.
  Future<void> clear() async {
    await _db
        .rawDelete("DELETE FROM Clients WHERE client=?", [client.clientName]);
    await schemes.forEach((String name, String scheme) async {
      if (name != "Clients") await db.rawDelete("DELETE FROM $name");
    });
    return;
  }

  Transaction txn;

  Future<void> transaction(Future<void> queries()) async {
    return client.store.db.transaction((txnObj) async {
      txn = txnObj;
      await queries();
    });
  }

  /// Will be automatically called on every synchronisation. Must be called inside of
  //  /// [transaction].
  Future<void> storePrevBatch(dynamic sync) {
    txn.rawUpdate("UPDATE Clients SET prev_batch=? WHERE client=?",
        [client.prevBatch, client.clientName]);
    return null;
  }

  Future<void> storeRoomPrevBatch(Room room) async {
    await _db.rawUpdate("UPDATE Rooms SET prev_batch=? WHERE room_id=?",
        [room.prev_batch, room.id]);
    return null;
  }

  /// Stores a RoomUpdate object in the database. Must be called inside of
  /// [transaction].
  Future<void> storeRoomUpdate(RoomUpdate roomUpdate) {
    // Insert the chat into the database if not exists
    txn.rawInsert(
        "INSERT OR IGNORE INTO Rooms " + "VALUES(?, ?, 0, 0, '', 0, 0, '') ",
        [roomUpdate.id, roomUpdate.membership.toString().split('.').last]);

    // Update the notification counts and the limited timeline boolean and the summary
    String updateQuery =
        "UPDATE Rooms SET highlight_count=?, notification_count=?, membership=?";
    List<dynamic> updateArgs = [
      roomUpdate.highlight_count,
      roomUpdate.notification_count,
      roomUpdate.membership.toString().split('.').last
    ];
    if (roomUpdate.summary?.mJoinedMemberCount != null) {
      updateQuery += ", joined_member_count=?";
      updateArgs.add(roomUpdate.summary.mJoinedMemberCount);
    }
    if (roomUpdate.summary?.mInvitedMemberCount != null) {
      updateQuery += ", invited_member_count=?";
      updateArgs.add(roomUpdate.summary.mInvitedMemberCount);
    }
    if (roomUpdate.summary?.mHeroes != null) {
      updateQuery += ", heroes=?";
      updateArgs.add(roomUpdate.summary.mHeroes.join(","));
    }
    updateQuery += " WHERE room_id=?";
    updateArgs.add(roomUpdate.id);
    txn.rawUpdate(updateQuery, updateArgs);

    // Is the timeline limited? Then all previous messages should be
    // removed from the database!
    if (roomUpdate.limitedTimeline) {
      txn.rawDelete("DELETE FROM Events WHERE chat_id=?", [roomUpdate.id]);
      txn.rawUpdate("UPDATE Rooms SET prev_batch=? WHERE id=?",
          [roomUpdate.prev_batch, roomUpdate.id]);
    }
    return null;
  }

  /// Stores an UserUpdate object in the database. Must be called inside of
  /// [transaction].
  Future<void> storeUserEventUpdate(UserUpdate userUpdate) {
    if (userUpdate.type == "account_data")
      txn.rawInsert("INSERT OR REPLACE INTO AccountData VALUES(?, ?)", [
        userUpdate.eventType,
        json.encode(userUpdate.content["content"]),
      ]);
    else if (userUpdate.type == "presence")
      txn.rawInsert("INSERT OR REPLACE INTO Presence VALUES(?, ?)", [
        userUpdate.eventType,
        userUpdate.content["sender"],
        json.encode(userUpdate.content["content"]),
      ]);
    return null;
  }

  /// Stores an EventUpdate object in the database. Must be called inside of
  /// [transaction].
  Future<void> storeEventUpdate(EventUpdate eventUpdate) {
    Map<String, dynamic> eventContent = eventUpdate.content;
    String type = eventUpdate.type;
    String chat_id = eventUpdate.roomID;

    // Get the state_key for m.room.member events
    String state_key = "";
    if (eventContent["state_key"] is String) {
      state_key = eventContent["state_key"];
    }

    if (type == "timeline" || type == "history") {
      // calculate the status
      num status = 2;
      if (eventContent["status"] is num) status = eventContent["status"];

      // Save the event in the database
      if ((status == 1 || status == -1) &&
          eventContent["unsigned"] is Map<String, dynamic> &&
          eventContent["unsigned"]["transaction_id"] is String)
        txn.rawUpdate(
            "UPDATE Events SET status=?, event_id=? WHERE event_id=?", [
          status,
          eventContent["event_id"],
          eventContent["unsigned"]["transaction_id"]
        ]);
      else
        txn.rawInsert(
            "INSERT OR REPLACE INTO Events VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
              eventContent["event_id"],
              chat_id,
              eventContent["origin_server_ts"],
              eventContent["sender"],
              eventContent["type"],
              json.encode(eventContent["unsigned"] ?? ""),
              json.encode(eventContent["content"]),
              json.encode(eventContent["prevContent"]),
              eventContent["state_key"],
              status
            ]);

      // Is there a transaction id? Then delete the event with this id.
      if (status != -1 &&
          eventUpdate.content.containsKey("unsigned") &&
          eventUpdate.content["unsigned"]["transaction_id"] is String)
        txn.rawDelete("DELETE FROM Events WHERE event_id=?",
            [eventUpdate.content["unsigned"]["transaction_id"]]);
    }

    if (type == "history") return null;

    if (eventUpdate.content["event_id"] != null) {
      txn.rawInsert(
          "INSERT OR REPLACE INTO RoomStates VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)",
          [
            eventContent["event_id"],
            chat_id,
            eventContent["origin_server_ts"],
            eventContent["sender"],
            state_key,
            json.encode(eventContent["unsigned"] ?? ""),
            json.encode(eventContent["prev_content"] ?? ""),
            eventContent["type"],
            json.encode(eventContent["content"]),
          ]);
    } else
      txn.rawInsert("INSERT OR REPLACE INTO RoomAccountData VALUES(?, ?, ?)", [
        eventContent["type"],
        chat_id,
        json.encode(eventContent["content"]),
      ]);

    return null;
  }

  /// Returns a User object by a given Matrix ID and a Room.
  Future<User> getUser({String matrixID, Room room}) async {
    List<Map<String, dynamic>> res = await db.rawQuery(
        "SELECT * FROM RoomStates WHERE state_key=? AND room_id=?",
        [matrixID, room.id]);
    if (res.length != 1) return null;
    return RoomState.fromJson(res[0], room).asUser;
  }

  /// Loads all Users in the database to provide a contact list
  /// except users who are in the Room with the ID [exceptRoomID].
  Future<List<User>> loadContacts({String exceptRoomID = ""}) async {
    List<Map<String, dynamic>> res = await db.rawQuery(
        "SELECT * FROM RoomStates WHERE state_key!=? AND room_id!=? GROUP BY state_key ORDER BY state_key",
        [client.userID, exceptRoomID]);
    List<User> userList = [];
    for (int i = 0; i < res.length; i++)
      userList
          .add(RoomState.fromJson(res[i], Room(id: "", client: client)).asUser);
    return userList;
  }

  /// Returns all users of a room by a given [roomID].
  Future<List<User>> loadParticipants(Room room) async {
    List<Map<String, dynamic>> res = await db.rawQuery(
        "SELECT * " +
            " FROM RoomStates " +
            " WHERE room_id=? " +
            " AND type='m.room.member'",
        [room.id]);

    List<User> participants = [];

    for (num i = 0; i < res.length; i++) {
      participants.add(RoomState.fromJson(res[i], room).asUser);
    }

    return participants;
  }

  /// Returns a list of events for the given room and sets all participants.
  Future<List<Event>> getEventList(Room room) async {
    List<Map<String, dynamic>> eventRes = await db.rawQuery(
        "SELECT * " +
            " FROM Events " +
            " WHERE room_id=?" +
            " GROUP BY event_id " +
            " ORDER BY origin_server_ts DESC",
        [room.id]);

    List<Event> eventList = [];

    for (num i = 0; i < eventRes.length; i++)
      eventList.add(Event.fromJson(eventRes[i], room));

    return eventList;
  }

  /// Returns all rooms, the client is participating. Excludes left rooms.
  Future<List<Room>> getRoomList(
      {bool onlyLeft = false,
      bool onlyDirect = false,
      bool onlyGroups = false}) async {
    if (onlyDirect && onlyGroups) return [];
    List<Map<String, dynamic>> res = await db.rawQuery("SELECT * " +
        " FROM Rooms" +
        " WHERE membership" +
        (onlyLeft ? "=" : "!=") +
        "'leave' " +
        " GROUP BY room_id ");
    List<Room> roomList = [];
    for (num i = 0; i < res.length; i++) {
      Room room = await Room.getRoomFromTableRow(res[i], client,
          states: getStatesFromRoomId(res[i]["id"]));
      roomList.add(room);
    }
    return roomList;
  }

  /// Returns a room without events and participants.
  Future<Room> getRoomById(String id) async {
    List<Map<String, dynamic>> res =
        await db.rawQuery("SELECT * FROM Rooms WHERE room_id=?", [id]);
    if (res.length != 1) return null;
    return Room.getRoomFromTableRow(res[0], client,
        states: getStatesFromRoomId(id));
  }

  Future<List<Map<String, dynamic>>> getStatesFromRoomId(String id) async {
    return db.rawQuery("SELECT * FROM RoomStates WHERE room_id=?", [id]);
  }

  Future<void> forgetRoom(String roomID) async {
    await db.rawDelete("DELETE FROM Rooms WHERE room_id=?", [roomID]);
    return;
  }

  /// Searches for the event in the store.
  Future<Event> getEventById(String eventID, Room room) async {
    List<Map<String, dynamic>> res = await db.rawQuery(
        "SELECT * FROM Events WHERE id=? AND room_id=?", [eventID, room.id]);
    if (res.length == 0) return null;
    return Event.fromJson(res[0], room);
  }

  Future<Map<String, AccountData>> getAccountData() async {
    Map<String, AccountData> newAccountData = {};
    List<Map<String, dynamic>> rawAccountData =
        await db.rawQuery("SELECT * FROM AccountData");
    for (int i = 0; i < rawAccountData.length; i++)
      newAccountData[rawAccountData[i]["type"]] =
          AccountData.fromJson(rawAccountData[i]);
    return newAccountData;
  }

  Future<Map<String, Presence>> getPresences() async {
    Map<String, Presence> newPresences = {};
    List<Map<String, dynamic>> rawPresences =
        await db.rawQuery("SELECT * FROM Presences");
    for (int i = 0; i < rawPresences.length; i++)
      newPresences[rawPresences[i]["type"]] =
          Presence.fromJson(rawPresences[i]);
    return newPresences;
  }

  Future forgetNotification(String roomID) async {
    await db
        .rawDelete("DELETE FROM NotificationsCache WHERE chat_id=?", [roomID]);
    return;
  }

  Future addNotification(String roomID, String event_id, int uniqueID) async {
    await db.rawInsert("INSERT INTO NotificationsCache VALUES (?, ?,?)",
        [uniqueID, roomID, event_id]);
    return;
  }

  Future<List<Map<String, dynamic>>> getNotificationByRoom(
      String room_id) async {
    List<Map<String, dynamic>> res = await db.rawQuery(
        "SELECT * FROM NotificationsCache WHERE chat_id=?", [room_id]);
    if (res.length == 0) return null;
    return res;
  }

  static final Map<String, String> schemes = {
    /// The database scheme for the Client class.
    "Clients": 'CREATE TABLE IF NOT EXISTS Clients(' +
        'client TEXT PRIMARY KEY, ' +
        'token TEXT, ' +
        'homeserver TEXT, ' +
        'matrix_id TEXT, ' +
        'device_id TEXT, ' +
        'device_name TEXT, ' +
        'prev_batch TEXT, ' +
        'matrix_versions TEXT, ' +
        'lazy_load_members INTEGER, ' +
        'UNIQUE(client))',

    /// The database scheme for the Room class.
    'Rooms': 'CREATE TABLE IF NOT EXISTS Rooms(' +
        'room_id TEXT PRIMARY KEY, ' +
        'membership TEXT, ' +
        'highlight_count INTEGER, ' +
        'notification_count INTEGER, ' +
        'prev_batch TEXT, ' +
        'joined_member_count INTEGER, ' +
        'invited_member_count INTEGER, ' +
        'heroes TEXT, ' +
        'UNIQUE(room_id))',

    /// The database scheme for the TimelineEvent class.
    'Events': 'CREATE TABLE IF NOT EXISTS Events(' +
        'event_id TEXT PRIMARY KEY, ' +
        'room_id TEXT, ' +
        'origin_server_ts INTEGER, ' +
        'sender TEXT, ' +
        'type TEXT, ' +
        'unsigned TEXT, ' +
        'content TEXT, ' +
        'prev_content TEXT, ' +
        'state_key TEXT, ' +
        "status INTEGER, " +
        'UNIQUE(event_id))',

    /// The database scheme for room states.
    'RoomStates': 'CREATE TABLE IF NOT EXISTS RoomStates(' +
        'event_id TEXT PRIMARY KEY, ' +
        'room_id TEXT, ' +
        'origin_server_ts INTEGER, ' +
        'sender TEXT, ' +
        'state_key TEXT, ' +
        'unsigned TEXT, ' +
        'prev_content TEXT, ' +
        'type TEXT, ' +
        'content TEXT, ' +
        'UNIQUE(room_id,state_key,type))',

    /// The database scheme for room states.
    'AccountData': 'CREATE TABLE IF NOT EXISTS AccountData(' +
        'type TEXT PRIMARY KEY, ' +
        'content TEXT, ' +
        'UNIQUE(type))',

    /// The database scheme for room states.
    'RoomAccountData': 'CREATE TABLE IF NOT EXISTS RoomAccountData(' +
        'type TEXT PRIMARY KEY, ' +
        'room_id TEXT, ' +
        'content TEXT, ' +
        'UNIQUE(type,room_id))',

    /// The database scheme for room states.
    'Presences': 'CREATE TABLE IF NOT EXISTS Presences(' +
        'type TEXT PRIMARY KEY, ' +
        'sender TEXT, ' +
        'content TEXT, ' +
        'UNIQUE(sender))',

    /// The database scheme for the NotificationsCache class.
    'NotificationsCache': 'CREATE TABLE IF NOT EXISTS NotificationsCache(' +
        'id int PRIMARY KEY, ' +
        'chat_id TEXT, ' + // The chat id
        'event_id TEXT, ' + // The matrix id of the Event
        'UNIQUE(event_id))',
  };
}
