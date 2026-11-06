// Live updates: the server nudges `notes:user:<id>` whenever this account's
// log grows (CLAUDE.md "Sync"); a nudge only triggers a pull, so data still
// moves through one path.

import { Socket } from "phoenix";

export interface Live {
  close(): void;
}

export function connectLive(opts: {
  socketUrl: string;
  userId: string;
  /** The current access token; read on every (re)connect. */
  token: () => string;
  onChanged: () => void;
  /** The socket failed or came back after a drop: worth a sync. */
  onTrouble: () => void;
}): Live {
  const socket = new Socket(opts.socketUrl, { params: () => ({ token: opts.token() }) });
  let joined = false;
  socket.onOpen(() => {
    // Back after a drop: catch up on anything missed meanwhile.
    if (joined) opts.onTrouble();
  });
  socket.onError(() => opts.onTrouble());
  socket.connect();
  const channel = socket.channel(`notes:user:${opts.userId}`);
  channel.on("changed", () => opts.onChanged());
  channel.join().receive("ok", () => {
    joined = true;
  });
  return {
    close() {
      channel.leave();
      socket.disconnect();
    },
  };
}
