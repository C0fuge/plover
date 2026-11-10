// Interop peer for tests/libhdfs3/digestmd5_test.cpp: the JDK's DIGEST-MD5 SaslServer (the implementation an
// HDFS DataNode uses for dfs.data.transfer.protection), protocol "hdfs", server name "0" as in
// SaslDataTransferServer. Run: java DigestServer.java <port-file> <qop list> <user> <password>
// Frames on the socket: 4-byte big-endian length + bytes.
// After the handshake: the server sends wrapped messages of several sizes; the client unwraps each and sends back
// the reversed bytes wrapped; the server unwraps and checks. Exit code 0 = all good.
import java.io.*;
import java.net.*;
import java.nio.file.*;
import java.util.*;
import javax.security.auth.callback.*;
import javax.security.sasl.*;

public class DigestServer {
    static void send(DataOutputStream out, byte[] b) throws IOException {
        out.writeInt(b.length);
        out.write(b);
        out.flush();
    }

    static byte[] recv(DataInputStream in) throws IOException {
        int n = in.readInt();
        byte[] b = new byte[n];
        in.readFully(b);
        return b;
    }

    public static void main(String[] args) throws Exception {
        String portFile = args[0], qop = args[1], user = args[2];
        char[] password = args[3].toCharArray();
        Map<String, Object> props = new HashMap<>();
        props.put(Sasl.QOP, qop);
        props.put(Sasl.SERVER_AUTH, "true");
        CallbackHandler cb = callbacks -> {
            for (Callback c : callbacks) {
                if (c instanceof NameCallback) {
                    NameCallback nc = (NameCallback) c;
                    if (!user.equals(nc.getDefaultName())) throw new IOException("unknown user " + nc.getDefaultName());
                } else if (c instanceof PasswordCallback) {
                    ((PasswordCallback) c).setPassword(password);
                } else if (c instanceof RealmCallback) {
                    RealmCallback rc = (RealmCallback) c;
                    rc.setText(rc.getDefaultText());
                } else if (c instanceof AuthorizeCallback) {
                    AuthorizeCallback ac = (AuthorizeCallback) c;
                    ac.setAuthorized(ac.getAuthenticationID().equals(ac.getAuthorizationID()));
                } else {
                    throw new UnsupportedCallbackException(c);
                }
            }
        };
        try (ServerSocket ss = new ServerSocket(0, 1, InetAddress.getLoopbackAddress())) {
            Files.write(Paths.get(portFile + ".tmp"), String.valueOf(ss.getLocalPort()).getBytes());
            Files.move(Paths.get(portFile + ".tmp"), Paths.get(portFile), StandardCopyOption.ATOMIC_MOVE);
            ss.setSoTimeout(30000);
            try (Socket s = ss.accept()) {
                s.setSoTimeout(30000);
                DataInputStream in = new DataInputStream(new BufferedInputStream(s.getInputStream()));
                DataOutputStream out = new DataOutputStream(new BufferedOutputStream(s.getOutputStream()));
                SaslServer sasl = Sasl.createSaslServer("DIGEST-MD5", "hdfs", "0", props, cb);
                byte[] challenge = sasl.evaluateResponse(new byte[0]);
                System.out.println("server challenge: " + new String(challenge, "UTF-8"));
                send(out, challenge);
                byte[] response = recv(in);
                System.out.println("client response: " + new String(response, "UTF-8"));
                byte[] rspauth = sasl.evaluateResponse(response);
                if (!sasl.isComplete()) throw new IllegalStateException("server not complete");
                send(out, rspauth);
                String negotiated = (String) sasl.getNegotiatedProperty(Sasl.QOP);
                System.out.println("negotiated qop " + negotiated);
                if (negotiated.equals("auth")) {
                    System.out.println("server OK (auth, no wrapping)");
                    return;
                }
                Random rnd = new Random(42);
                int[] sizes = {1, 5, 6, 7, 8, 9, 15, 16, 17, 100, 1000, 4096, 65000};
                for (int round = 0; round < 3; round++) {
                    for (int n : sizes) {
                        byte[] msg = new byte[n];
                        rnd.nextBytes(msg);
                        send(out, sasl.wrap(msg, 0, msg.length));
                        byte[] back = recv(in);
                        byte[] plain = sasl.unwrap(back, 0, back.length);
                        byte[] want = new byte[n];
                        for (int i = 0; i < n; i++) want[i] = msg[n - 1 - i];
                        if (!Arrays.equals(plain, want)) throw new IllegalStateException("echo mismatch at size " + n);
                    }
                }
                send(out, new byte[0]); // end marker (unwrapped, zero length)
                System.out.println("server OK (" + negotiated + ", " + 3 * sizes.length + " messages each way)");
            }
        }
    }
}
