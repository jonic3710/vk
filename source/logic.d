/*
Copyright 2016 HaCk3D, substanceof

https://github.com/HaCk3Dq
https://github.com/substanceof

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

module logic;

import std.stdio, std.conv, std.string, std.regex, std.array, std.datetime, std.random, core.time;
import std.exception, core.exception, std.process;
import std.net.curl, std.uri, std.json;
import std.range, std.algorithm;
import std.parallelism, std.concurrency, core.thread, core.sync.mutex;
import utils, cache, localization, vkapi;

const int defaultLoadCount = 100;

__gshared {
    Async async;
}

class Async {
    alias taskfunc = void delegate();

    class task : Thread {
        this(taskfunc f, string name) {
            threadName = name;
            func = f;
            super(&thrfunc);
            this.start();
        }

        private void thrfunc() {
            try func();
            catch (Exception e) {
                dbm("Thread " ~ threadName ~ " exception: " ~
                    typeof(e).stringof ~ " " ~ e.msg);
            }
            catch (Error r) {
                dbm("Thread " ~ threadName ~ " error: " ~ r.msg);
            }
        }

        taskfunc func;
        string threadName;
    }

    class taskqueue : Thread {
        struct queuetask {
            taskfunc func;
            int rid;
        }

        this(string name) {
            threadName = name;
            super(&thrfunc);
        }

        private void thrfunc() {
            while(true) {
                for(int i; i < queue.length; ++i) {
                    auto ctask = queue[i];
                    runningRid = ctask.rid;

                    try ctask.func();
                    catch (Exception e) {
                        dbm("Thread " ~ threadName ~ " exception: " ~ e.msg);
                    }
                    catch (Error r) {
                        dbm("Thread " ~ threadName ~ " error: " ~ r.msg);
                    }

                    runningRid = 0;
                }
                queue = []; // clear queue
                dbm("async: queue cleared for " ~ threadName);
                while(queue.length == 0) Thread.sleep(dur!"msecs"(300));
            }
        }

        void add(taskfunc f, int rid) {
            queue ~= queuetask(f, rid);
        }

        queuetask[] queue;
        int runningRid;
        string threadName;
    }

    task[string] singles;
    taskqueue[string] queues;

    const string
        q_loadChunk = "q_load_chunk";

    void single(string name, taskfunc f) {
        auto t = name in singles;
        if( (t && !t.isRunning) || !t ) {
            singles[name] = new task(f, name);
            dbm("async: thread started for " ~ name);
        }
        else {
            dbm("async: single " ~ name ~ " already running!");
        }
    }

    void queue(string name, int rid, taskfunc f) {
        auto e = name in queues;
        if(e) {
            auto query = e.queue.filter!(q => q.rid == rid);
            if(query.empty || query.map!(q => q.rid != e.runningRid).all!"a") {
                e.add(f, rid);
            }
            else {
                dbm("async: already has task with this rid in query!!");
            }
        }
        else {
            auto nq = new taskqueue(name);
            nq.add(f, rid);
            nq.start();
            queues[name] = nq;
            dbm("async: thread started for " ~ name ~ " queue");
        }
    }
}

class Chunk(T) {
    this(T[] obj, int off) {
        objects = obj;
        offset = off;
    }

    T[] objects;
    int offset;
    size_t count() { return objects.length; }
    size_t end() { return offset + count(); }
}

class MergedChunks(T) {
    alias typedchunk = Chunk!T;

    private {
        Storage!T meta;
        typedchunk last;
        bool lastempty;
        size_t iter;
        size_t localiter;
        size_t countiter;
        size_t max;
    }

    this(Storage!T s, int pos, int count) {
        meta = s;
        iter = pos;
        max = count;
    }

    private void findchunk() {
        auto query = meta.store
            .retro
            .filter!(q => q.offset <= iter);
        if(!query.empty) {
            last = query.front();
            lastempty = false;
            localiter = iter - last.offset;
        }
        else {
            lastempty = true;
            meta.load(iter.to!int, defaultLoadCount);
        }
    }

    void popFront() {
        ++iter;
        ++localiter;
        ++countiter;
    }

    T front() {
        if(empty()) return null; // todo check need exception
        return last.objects[localiter];
    }

    bool empty() {
        if(countiter >= max) return true;
        if(last is null || localiter >= last.count || lastempty) {
            findchunk();
        }
        return lastempty;
    }

    auto moveFront() {
        return front();
    }

}

class Storage(T) {
    alias typedchunk = Chunk!T;
    alias typecoll = T[];
    alias loader = typecoll delegate(int offset, int count);

    private {
        loader loadfunc;
        int asyncId;
    }

    typedchunk[] store;

    this(loader loadf) {
        loadfunc = loadf;
        asyncId = genId();
    }

    private void loadSync(int pos, int count) {
        auto freshChunk = loadfunc(pos, count);
        store ~= new Chunk!T(freshChunk, pos);
    }

    void load(int pos, int count) {
        async.queue(async.q_loadChunk, asyncId, () => loadSync(pos, count));
    }

    auto get(int pos, int count) {
        return new MergedChunks!T(this, pos, count);
    }
}

abstract class SuperView(T) {
    MergedChunks!T getView(int height, int width);
    void moveForward(int step = 1);
    void moveBackward(int step = 1);
}

class View(T) : SuperView!T {
    alias storageType = Storage!T;

    private {
        size_t position;
    }

    storageType storage;

    this(storageType st) {
        storage = st;
    }

    override MergedChunks!T getView(int height, int width) {
        return storage.get(position.to!int, height);
    }

    override void moveForward(int step = 1) {
        position += step;
        // todo preload
    }

    override void moveBackward(int step = 1) {
        position -= step;
        if(position < 0) position = 0;
    }
}

enum list {
    dialogs,
    friends,
    muic
}

class MainProvider {
    VkApi api;

    //define list views
    View!User friendsList;
    View!Audio musicList;
    View!Dialog dialogList;

    this(string token) {
        api = new VkApi(token);
        init();
    }

    this(string token, int uid, string fname, string lname) {
        api = new VkApi(token);
        describeMe(uid, fname, lname);
        init();
    }

    private void init() {
        async = new Async();
        api.accountInit();

        //init lists
        friendsList = new View!User(new Storage!User((o, c) => api.friendsGet(c, o)));

    }

    private void describeMe(int uid, string fname, string lname) {
        auto me = new User();
        me.id = uid;
        me.firstName = fname;
        me.lastName = lname;
        me.init();
        api.me = me;
    }

}

