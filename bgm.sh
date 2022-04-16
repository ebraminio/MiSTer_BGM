#!/usr/bin/env python

import os
import sys
import subprocess
import threading
import random
import math
import socket
import configparser
import datetime
import time
import signal

DEFAULT_PLAYLIST = "random"
MUSIC_FOLDER = "/media/fat/music"
HISTORY_SIZE = 0.2  # ratio of total tracks to keep in play history
SOCKET_FILE = "/tmp/bgm.sock"
MESSAGE_SIZE = 32
SCRIPTS_FOLDER = "/media/fat/Scripts"
STARTUP_SCRIPT = "/media/fat/linux/user-startup.sh"
CORENAME_FILE = "/tmp/CORENAME"
LOG_FILE = "/tmp/bgm.log"
INI_FILENAME = "bgm.ini"
MENU_CORE = "MENU"
DEBUG = False


# TODO: way to make it run sooner? put in docs how to add service file
# TODO: remote control http server, separate file
# TODO: folder based playlists
# TODO: internet radio?

# read ini file
ini_file = os.path.join(MUSIC_FOLDER, INI_FILENAME)
if os.path.exists(ini_file):
    ini = configparser.ConfigParser()
    ini.read(ini_file)
    DEFAULT_PLAYLIST = ini.get("bgm", "playlist", fallback=DEFAULT_PLAYLIST)
    DEBUG = ini.getboolean("bgm", "debug", fallback=DEBUG)
else:
    # create a default ini
    if os.path.exists(MUSIC_FOLDER):
        with open(ini_file, "w") as f:
            f.write("[bgm]\nplaylist = random\ndebug = no\n")


def log(msg: str, always_print=False):
    if msg == "":
        return
    if always_print or DEBUG:
        print(msg)
    if DEBUG:
        with open(LOG_FILE, "a") as f:
            f.write(
                "[{}] {}\n".format(
                    datetime.datetime.isoformat(datetime.datetime.now()), msg
                )
            )


def random_index(list):
    return random.randint(0, len(list) - 1)


def get_core():
    if not os.path.exists(CORENAME_FILE):
        return None

    with open(CORENAME_FILE) as f:
        return str(f.read())


def wait_core_change():
    if get_core() is None:
        log("CORENAME file does not exist, retrying...")
        # keep trying to read it for a little while
        attempts = 0
        while get_core() is None and attempts <= 15:
            time.sleep(1)
            attempts += 1
        if get_core() is None:
            log("No CORENAME file found")
            return None

    # TODO: check for errors from this
    args = ("inotifywait", "-e", "modify", CORENAME_FILE)
    monitor = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    while monitor is not None and monitor.poll() is None:
            line = monitor.stdout.readline()
            log(line.decode().rstrip())

    core = get_core()
    log("Core change to: {}".format(core))
    return core


# TODO: vgmplay support
# TODO: disable playlist (boot sound only)
# TODO: per track loop options (filename?)
class Player:
    player = None
    # TODO: current playlist, and ability to change it
    end_playlist = threading.Event()
    history = []

    def is_mp3(self, filename: str):
        return filename.lower().endswith(".mp3")

    def is_ogg(self, filename: str):
        return filename.lower().endswith(".ogg")

    def is_wav(self, filename: str):
        return filename.lower().endswith(".wav")

    # TODO: this might get crazy if vgmplay is added. use a regex?
    def is_valid_file(self, filename: str):
        return self.is_mp3(filename) or self.is_ogg(filename) or self.is_wav(filename)

    def play_mp3(self, filename: str):
        args = ("mpg123", "--no-control", filename)
        self.player = subprocess.Popen(
            args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
        )
        # workaround for a strange issue with mpg123 on MiSTer
        # some mp3 files will play but cause mpg123 to hang at the end
        # this may be fixed when MiSTer ships with a newer version
        while self.player is not None:
            line = self.player.stdout.readline()
            output = line.decode().rstrip()
            log(output)
            if "finished." in output or self.player is None or self.player.poll() is not None:
                self.stop()
                break

    def play_ogg(self, filename: str):
        args = ("ogg123", filename)
        self.player = subprocess.Popen(
            args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
        )
        while self.player is not None and self.player.poll() is None:
            line = self.player.stdout.readline()
            log(line.decode().rstrip())
        self.stop()

    def play_wav(self, filename: str):
        args = ("aplay", filename)
        self.player = subprocess.Popen(
            args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
        )
        while self.player is not None and self.player.poll() is None:
            line = self.player.stdout.readline()
            log(line.decode().rstrip())
        self.stop()

    def all_tracks(self):
        tracks = []

        for track in os.listdir(MUSIC_FOLDER):
            if not track.startswith("_") and self.is_valid_file(track):
                tracks.append(track)

        return tracks

    def total_tracks(self):
        return len(self.all_tracks())

    def add_history(self, filename: str):
        history_size = math.floor(self.total_tracks() * HISTORY_SIZE)
        if history_size < 1:
            return
        while len(self.history) > history_size:
            self.history.pop(0)
        self.history.append(filename)

    def stop(self):
        if self.player is not None:
            self.player.kill()
            self.player = None

    def play(self, filename: str):
        self.stop()

        if self.is_valid_file(filename):
            self.add_history(filename)
            log("Now playing: {}".format(filename))
        else:
            return

        if self.is_mp3(filename):
            self.play_mp3(filename)
        elif self.is_ogg(filename):
            self.play_ogg(filename)
        elif self.is_wav(filename):
            self.play_wav(filename)

    def get_random_track(self):
        tracks = self.all_tracks()
        if len(tracks) == 0:
            return

        index = random_index(tracks)
        # avoid replaying recent tracks
        while tracks[index] in self.history:
            index = random_index()

        return os.path.join(MUSIC_FOLDER, tracks[index])

    def play_random(self):
        self.play(self.get_random_track())

    def start_random_playlist(self):
        self.stop()
        log("Starting random playlist...")
        self.end_playlist.clear()

        def playlist_loop():
            while not self.end_playlist.is_set():
                self.play_random()
            log("Random playlist ended")

        playlist = threading.Thread(target=playlist_loop)
        playlist.start()

    def start_loop_playlist(self):
        self.stop()
        log("Starting loop playlist...")
        self.end_playlist.clear()

        track = self.get_random_track()

        def playlist_loop():
            while not self.end_playlist.is_set():
                self.play(track)
            log("Loop playlist ended")

        playlist = threading.Thread(target=playlist_loop)
        playlist.start()

    def start_playlist(self, name):
        if name == "random":
            self.start_random_playlist()
        elif name == "loop":
            self.start_loop_playlist()
        else:
            # random playlist is fallback
            self.start_random_playlist()

    def stop_playlist(self):
        self.end_playlist.set()
        self.stop()

    def start_remote(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.bind(SOCKET_FILE)

        def handler(cmd):
            log("Received command: {}".format(cmd))
            if cmd == "stop":
                self.stop_playlist()
            elif cmd == "play":
                self.stop_playlist()
                self.start_playlist(DEFAULT_PLAYLIST)
            elif cmd == "skip":
                self.stop()
            elif cmd == "pid":
                return os.getpid()

        def listener():
            while True:
                s.listen()
                conn, addr = s.accept()
                data = conn.recv(MESSAGE_SIZE).decode()
                if data == "quit":
                    break
                response = handler(data)
                if response is not None:
                    conn.send(str(response).encode())
                conn.close()
            s.close()
            log("Remote stopped")

        log("Starting remote...")
        remote = threading.Thread(target=listener)
        remote.start()

    def get_boot_track(self):
        boot_tracks = []

        for name in os.listdir(MUSIC_FOLDER):
            if name.startswith("_") and self.is_valid_file(name):
                boot_tracks.append(os.path.join(MUSIC_FOLDER, name))

        if len(boot_tracks) > 0:
            return boot_tracks[random_index(boot_tracks)]
        else:
            return None

    def play_boot(self):
        track = self.get_boot_track()
        if track is not None:
            log("Selected boot track: {}".format(track))
            self.play(track)


def send_socket(msg: str):
    if not os.path.exists(SOCKET_FILE):
        return
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(SOCKET_FILE)
    s.send(msg.encode())
    response = s.recv(MESSAGE_SIZE)
    s.close()
    if len(response) > 0:
        return response.decode()
    

def cleanup(player: Player):
    if player is not None:
        player.stop_playlist()
        send_socket("quit")
    if os.path.exists(SOCKET_FILE):
        os.remove(SOCKET_FILE)


def start_service(player: Player):
    log("Starting service...")

    player.start_remote()
    # TODO: make this non-blocking so it can be cut off during core launch?
    player.play_boot()

    if player.total_tracks() == 0:
        log("No tracks available to play")
        return

    core = get_core()
    # don't start playing if the boot track ran into a core launch
    # do start playing for a bit if the CORENAME file is still being created
    if core == MENU_CORE or core is None:
        player.start_playlist(DEFAULT_PLAYLIST)

    while True:
        new_core = wait_core_change()

        if new_core is None:
            log("CORENAME file is missing, exiting...")
            break
        
        if core == new_core:
            pass
        elif new_core == MENU_CORE:
            log("Switched to menu core, starting playlist...")
            player.start_playlist(DEFAULT_PLAYLIST)
        elif new_core != MENU_CORE:
            log("Exited menu core, stopping playlist...")
            player.stop_playlist()

        core = new_core


def try_add_to_startup():
    if not os.path.exists(STARTUP_SCRIPT):
        # create a new startup script
        with open(STARTUP_SCRIPT, "w") as f:
            f.write("#!/bin/sh\n")

    with open(STARTUP_SCRIPT, "r") as f:
        if "Startup BGM" in f.read():
            return

    with open(STARTUP_SCRIPT, "a") as f:
        bgm = os.path.join(SCRIPTS_FOLDER, "bgm.sh")
        f.write("\n# Startup BGM\n[[ -e {} ]] && {} $1 &\n".format(bgm, bgm))
        log("Added service to startup script.", True)


# TODO: these scripts should say if socket doesn't exist
def try_create_control_scripts():
    template = (
        '#!/usr/bin/env bash\n\necho -n "{}" | socat - UNIX-CONNECT:{}\n'
    )
    for cmd in ("play", "stop", "skip"):
        script = os.path.join(SCRIPTS_FOLDER, "bgm_{}.sh".format(cmd, SOCKET_FILE))
        if not os.path.exists(script):
            with open(script, "w") as f:
                f.write(template.format(cmd))
                log("Created {} script.".format(cmd), True)


if __name__ == "__main__":
    if len(sys.argv) == 2:
        if sys.argv[1] == "start":
            if os.path.exists(SOCKET_FILE):
                log("BGM service is already running, exiting...", True)
                sys.exit()
            def stop(sn=0, f=0):
                log("Stopping service ({})".format(sn))
                cleanup(player)
                sys.exit()
            signal.signal(signal.SIGINT, stop)
            signal.signal(signal.SIGTERM, stop)
            player = Player()
            start_service(player)
            stop()
        elif sys.argv[1] == "stop":
            if not os.path.exists(SOCKET_FILE):
                log("BGM service is not running", True)
                sys.exit()
            pid = send_socket("pid")
            if pid is not None:
                os.system("kill {}".format(pid))
            sys.exit()

    if not os.path.exists(MUSIC_FOLDER):
        os.mkdir(MUSIC_FOLDER)
        log("Created music folder.", True)
    try_add_to_startup()
    try_create_control_scripts()

    player = Player()
    if player.total_tracks() == 0:
        log(
            "Add music files to {} and re-run this script to start.".format(
                MUSIC_FOLDER
            ),
            True,
        )
        sys.exit()
    else:
        if not os.path.exists(SOCKET_FILE):
            log("Starting BGM service...", True)
            os.system("{} start &".format(os.path.join(SCRIPTS_FOLDER, "bgm.sh")))
            sys.exit()
        else:
            log("BGM is already running.", True)
            sys.exit()
