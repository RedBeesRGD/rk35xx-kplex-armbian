import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DumpDecomp extends GhidraScript {
    @Override
    public void run() throws Exception {
        DecompInterface di = new DecompInterface();
        di.openProgram(currentProgram);
        PrintWriter w = new PrintWriter(new FileWriter("/tmp/skwre-4dc4c7b1/decomp.c"));
        FunctionIterator it = currentProgram.getFunctionManager().getFunctions(true);
        int n = 0, ok = 0;
        while (it.hasNext() && !monitor.isCancelled()) {
            Function f = it.next();
            n++;
            DecompileResults r = di.decompileFunction(f, 45, monitor);
            if (r != null && r.decompileCompleted()) {
                w.println("/*=== " + f.getName() + " @ " + f.getEntryPoint() + " ===*/");
                w.println(r.getDecompiledFunction().getC());
                ok++;
            }
        }
        w.close();
        println("FUNCTIONS_TOTAL=" + n + " DECOMPILED=" + ok);
    }
}
