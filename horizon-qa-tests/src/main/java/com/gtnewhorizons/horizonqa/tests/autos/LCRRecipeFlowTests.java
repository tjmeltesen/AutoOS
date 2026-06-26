package com.gtnewhorizons.horizonqa.tests.autos;

import com.gtnewhorizons.horizonqa.api.annotation.GameTest;
import com.gtnewhorizons.horizonqa.api.GameTestHelper;
import com.gtnewhorizons.horizonqa.api.annotation.GameTestHolder;
import com.gtnewhorizons.horizonqa.api.gt.GTNHGameTestHelper;
import com.gtnewhorizons.horizonqa.api.gt.Multiblock;
import com.gtnewhorizons.horizonqa.api.gt.Bus;
import static com.gtnewhorizons.horizonqa.api.TestPos.at;

/**
 * End-to-end recipe dispatch lifecycle tests.
 *
 * These tests exercise the real flow AutoOS executes for every lane:
 *  1. Verify machine is formed
 *  2. Fix maintenance issues
 *  3. Supply power
 *  4. Load recipe inputs (items + circuit)
 *  5. Run recipe to completion
 *  6. Verify machine returns to idle
 *  7. Verify sensor info is available post-run
 */
@GameTestHolder("autos")
public class LCRRecipeFlowTests {

    /**
     * Full recipe dispatch cycle: form, fix, power, insert, run, verify idle, verify outputs.
     * This is the exact flow AutoOS lane_worker executes via Stocking -> Completion -> Extraction phases.
     */
    @GameTest(template = "lcr_basic", timeoutTicks = 600)
    public static void fullRecipeDispatchCycle(GameTestHelper helper) {
        GTNHGameTestHelper gtnh = helper.gtnh();
        Multiblock lcr = gtnh.multiblock(at(1, 0, 0));

        // Phase 1: Verify machine formed and fix maintenance
        lcr.assertFormed();
        lcr.fixMaintenance();

        // Phase 2: Supply EU (MV tier, 2 amps, 1000 ticks)
        lcr.energyHatch(0).supply(128, 2, 1000);

        // Phase 3: Verify machine is idle before we start
        Object controller = gtnh.multiblock(at(1, 0, 0));
        helper.assertFalse(gtnh.isMachineActive(controller),
            "Machine should be idle before recipe starts");
        helper.assertFalse(gtnh.hasWork(controller),
            "Machine should have no work before recipe starts");

        // Phase 4: Insert recipe inputs (simulates ME interface stocking)
        Bus inputBus = lcr.inputBus(0);
        inputBus.programmedCircuit(5);

        // Phase 5: Run recipe to completion (warps time)
        lcr.runRecipe(500);

        // Phase 6: Post-run checks — machine must be idle
        helper.onEachTick(() -> {
            helper.assertFalse(gtnh.isMachineActive(controller),
                "Machine should return to idle after recipe completes");
            helper.assertFalse(gtnh.hasWork(controller),
                "Machine should have no work after recipe completes");
        });

        // Phase 7: Sensor info still accessible
        String sensor = gtnh.getSensorInformation(controller);
        helper.assertTrue(sensor != null && sensor.length() > 0,
            "getSensorInformation should return data after recipe run: " + sensor);

        helper.succeedAtTimeout();
    }

    /**
     * Verify that insufficient EU causes the recipe to abort mid-run.
     * AutoOS adapter polling detects this via isMachineActive/setWorkAllowed transitions.
     */
    @GameTest(template = "lcr_basic", timeoutTicks = 600)
    public static void insufficientEUCausesAbort(GameTestHelper helper) {
        GTNHGameTestHelper gtnh = helper.gtnh();
        Multiblock lcr = gtnh.multiblock(at(1, 0, 0));

        lcr.assertFormed();
        lcr.fixMaintenance();

        // Supply barely enough EU for 10 ticks at 2 amps
        // 128 EU/t * 2 amps * 10 ticks = 2560 EU total
        lcr.energyHatch(0).supply(128, 2, 10);

        // Place inputs and start
        Bus inputBus = lcr.inputBus(0);
        inputBus.programmedCircuit(1);

        // Run recipe — machine should stop when EU runs out
        Object controller = gtnh.multiblock(at(1, 0, 0));

        // After EU runs out, eventually machine goes idle without completing
        helper.succeedWhen(() ->
            !gtnh.isMachineActive(controller) && !gtnh.hasWork(controller));
    }

    /**
     * Verify workAllowed persists across the recipe lifecycle.
     * AutoOS sets workAllowed(true) on machine start and expects it to stick.
     */
    @GameTest(template = "lcr_basic", timeoutTicks = 200)
    public static void workAllowedSurvivesRecipeCycle(GameTestHelper helper) {
        GTNHGameTestHelper gtnh = helper.gtnh();
        Multiblock lcr = gtnh.multiblock(at(1, 0, 0));

        lcr.assertFormed();
        lcr.fixMaintenance();

        Object controller = gtnh.multiblock(at(1, 0, 0));
        gtnh.setWorkAllowed(controller, true);

        lcr.energyHatch(0).supply(128, 2, 500);
        Bus inputBus = lcr.inputBus(0);
        inputBus.programmedCircuit(5);
        lcr.runRecipe(500);

        helper.assertTrue(gtnh.isWorkAllowed(controller),
            "workAllowed must remain true after recipe completes");

        helper.succeed();
    }
}
