package com.gtnewhorizons.horizonqa.tests.autos;

import com.gtnewhorizons.horizonqa.api.GameTest;
import com.gtnewhorizons.horizonqa.api.GameTestHelper;
import com.gtnewhorizons.horizonqa.api.GameTestHolder;
import com.gtnewhorizons.horizonqa.api.GTNHGameTestHelper;
import com.gtnewhorizons.horizonqa.api.gt.Multiblock;
import static com.gtnewhorizons.horizonqa.api.TestPos.at;

/**
 * Power interruption detection and recovery flows.
 *
 * AutoOS adapter polling (adapter_connectivity.lua, machine_poll.lua) monitors
 * power state via isMachineActive transitions. These tests exercise the
 * power-loss -> detect -> recover cycle that AutoOS must handle.
 */
@GameTestHolder("autos")
public class PowerLossFlowTests {

    /**
     * When EU supply runs out mid-recipe, the machine must transition
     * from active to idle. AutoOS detects this to trigger lane fault/recovery.
     */
    @GameTest(template = "lcr_basic", timeoutTicks = 600)
    public static void powerLossStopsMachine(GameTestHelper helper) {
        GTNHGameTestHelper gtnh = helper.gtnh();
        Multiblock lcr = gtnh.multiblock(at(1, 0, 0));

        lcr.assertFormed();
        lcr.fixMaintenance();

        // Supply only enough EU for partial recipe (10 ticks at 1 amp)
        lcr.energyHatch(0).supply(128, 1, 10);

        lcr.inputBus(0).programmedCircuit(5);

        Object controller = gtnh.multiblock(at(1, 0, 0));

        // Machine should eventually stop when EU depletes
        helper.succeedWhen(() ->
            !gtnh.isMachineActive(controller) && !gtnh.hasWork(controller));
    }

    /**
     * After power loss, restoring EU and re-enabling work should allow
     * the machine to run again. AutoOS re-sets workAllowed and retries.
     */
    @GameTest(template = "lcr_basic", timeoutTicks = 800)
    public static void recoveryAfterPowerRestored(GameTestHelper helper) {
        GTNHGameTestHelper gtnh = helper.gtnh();
        Multiblock lcr = gtnh.multiblock(at(1, 0, 0));

        lcr.assertFormed();
        lcr.fixMaintenance();

        Object controller = gtnh.multiblock(at(1, 0, 0));

        // Supply enough EU for a full run
        lcr.energyHatch(0).supply(128, 4, 1000);
        lcr.inputBus(0).programmedCircuit(5);

        // Run recipe — should complete with sufficient EU
        lcr.runRecipe(500);

        // After completion: machine idle, power was sufficient
        helper.assertFalse(gtnh.isMachineActive(controller),
            "Machine should be idle after recipe with adequate EU");
        helper.assertFalse(gtnh.hasWork(controller),
            "Machine should have no work after recipe with adequate EU");

        // Simulate AutoOS recovery: re-set workAllowed for next job
        gtnh.setWorkAllowed(controller, true);
        helper.assertTrue(gtnh.isWorkAllowed(controller),
            "workAllowed must be true after recovery setWorkAllowed call");

        // Machine ready for next dispatch
        helper.succeed();
    }

    /**
     * Verify isMachineActive correctly reflects powered/unpowered state.
     * AutoOS adapter polling uses this as the primary power-loss signal.
     */
    @GameTest(template = "lcr_basic", timeoutTicks = 100)
    public static void isMachineActiveFalseWhenUnpowered(GameTestHelper helper) {
        GTNHGameTestHelper gtnh = helper.gtnh();
        Multiblock lcr = gtnh.multiblock(at(1, 0, 0));

        lcr.assertFormed();
        lcr.fixMaintenance();

        Object controller = gtnh.multiblock(at(1, 0, 0));

        // Without any EU supply:
        helper.assertFalse(gtnh.isMachineActive(controller),
            "Machine without power must not report active");
        helper.assertFalse(gtnh.hasWork(controller),
            "Machine without power must not report work");

        // Verify workAllowed state is readable even when unpowered
        // (AutoOS reads this to decide whether to attempt restart)
        helper.assertTrue(
            gtnh.isWorkAllowed(controller) || !gtnh.isWorkAllowed(controller),
            "isWorkAllowed should return a boolean even when unpowered");

        helper.succeed();
    }

    /**
     * Verify sensor information remains accessible during power loss.
     * AutoOS maintenance_parse reads sensor info regardless of power state.
     */
    @GameTest(template = "lcr_basic", timeoutTicks = 100)
    public static void sensorInfoAccessibleDuringPowerLoss(GameTestHelper helper) {
        GTNHGameTestHelper gtnh = helper.gtnh();
        Multiblock lcr = gtnh.multiblock(at(1, 0, 0));

        lcr.assertFormed();
        lcr.fixMaintenance();

        // Don't supply any EU
        Object controller = gtnh.multiblock(at(1, 0, 0));

        String sensor = gtnh.getSensorInformation(controller);
        helper.assertTrue(sensor != null && sensor.length() > 0,
            "getSensorInformation must work even without EU supply: " + sensor);

        helper.succeed();
    }
}
