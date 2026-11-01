// Prints a one-line fingerprint per chart using beatoraja's parser (jbms-parser).
// Run: javac -cp LR2oraja.jar -d /tmp/x DumpChart.java && java -cp LR2oraja.jar:/tmp/x DumpChart <list-file>
import bms.model.*;
import java.nio.file.*;
import java.util.*;

public class DumpChart {
    public static void main(String[] args) throws Exception {
        java.util.logging.LogManager.getLogManager().reset();
        int[] ones = new int[256];
        Arrays.fill(ones, 1);
        for (String f : Files.readAllLines(Paths.get(args[0]))) {
            byte[] data = Files.readAllBytes(Paths.get(f));
            String low = f.toLowerCase();
            BMSModel m;
            if (low.endsWith(".bmson")) {
                m = new BMSONDecoder(BMSModel.LNTYPE_LONGNOTE).decode(Paths.get(f));
            } else {
                m = new BMSDecoder(BMSModel.LNTYPE_LONGNOTE).decode(data, low.endsWith(".pms"), ones);
            }
            if (m == null) { System.out.println(f + "\tFAILED"); continue; }
            long h = 0xcbf29ce484222325L;
            int keys = m.getMode().key;
            for (TimeLine tl : m.getAllTimeLines()) {
                for (int lane = 0; lane < keys; lane++) {
                    Note n = tl.getNote(lane);
                    if (n == null) continue;
                    int kind = n instanceof NormalNote ? 0 : n instanceof MineNote ? 3 : (((LongNote) n).isEnd() ? 2 : 1);
                    h = mix(h, tl.getMicroTime()); h = mix(h, lane); h = mix(h, kind); h = mix(h, n.getWav() < 0 ? -1 : n.getWav());
                }
            }
            System.out.println(f + "\t" + (m.getMD5() == null ? "" : m.getMD5()) + "\t" + m.getSHA256() + "\t" + m.getMode().key + "\t"
                + m.getTotalNotes() + "\t" + m.getLastMilliTime() + "\t" + m.getLastNoteMilliTime() + "\t" + Long.toHexString(h));
        }
    }
    static long mix(long h, long v) { return (h ^ v) * 0x100000001b3L; }
}
