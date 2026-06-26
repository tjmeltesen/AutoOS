package autos;

import com.gtnewhorizons.horizonqa.api.GameTest;
import com.gtnewhorizons.horizonqa.api.GameTestHelper;
import com.gtnewhorizons.horizonqa.api.GameTestHolder;
import com.gtnewhorizons.horizonqa.api.GTNHGameTestHelper;
import com.gtnewhorizons.horizonqa.api.gt.Multiblock;
import com.gtnewhorizons.horizonqa.api.gt.Bus;
import static com.gtnewhorizons.horizonqa.api.TestPos.at;

/**
 * Circuit programming and extraction flows.
 *
 * AutoOS circuit_manager.lua handles: programmed circuit insertion before recipe,
 * circuit detection via stack scanning, and extraction after recipe completion.
 * These tests exercise the full circuit lifecycle.
 */
@GameTestHolder("autos")
public class CircuitFlowTests {

    /**
     * Program a circuit into the input bus, run a recipe, verify circuit
     * is still in the bus afterward for extraction. AutoOS extracts circuits
     * back through the transposer after recipe completion.
     */
    @GameTest(template = "lcr_basic", timeoutTicks = 600)
    public static void circuitSurvivesRecipeCycle(GameTestHelper helper) {
        GTNHGameTestHelper gtnh = helper.gtnh();
        Multiblock lcr = gtnh.multiblock(at(1, 0, 0));

        lcr.assertFormed();
        lcr.fixMaintenance();

        // Program circuit config 5
        Bus inputBus = lcr.inputBus(0);
        inputBus.programmedCircuit(5);

        // Verify circuit is in the bus before running
        inputBus.assertContains(
            com.gtnewhorizons.horizonqa.api.gt.ItemMatcher.circuit(5));

        // Run recipe
        lcr.energyHatch(0).supply(128, 2, 500);
        lcr.runRecipe(500);

        // After recipe: circuit should still be in the bus (configurable circuit slot)
        inputBus.assertContains(
            com.gtnewhorizons.horizonqa.api.gt.ItemMatcher.circuit(5));

        helper.succeed();
    }

    /**
     * Test multiple circuit configurations to verify all config values work.
     * AutoOS supports circuits 1-24 for recipe selection.
     */
    @GameTest(template = "lcr_basic", timeoutTicks = 1200)
    public static void multipleCircuitConfigsWork(GameTestHelper helper) {
        GTNHGameTestHelper gtnh = helper.gtnh();
        Multiblock lcr = gtnh.multiblock(at(1, 0, 0));

        lcr.assertFormed();
        lcr.fixMaintenance();
        lcr.energyHatch(0).supply(128, 4, 1000);

        Bus inputBus = lcr.inputBus(0);

        // Test circuit config 1
        inputBus.programmedCircuit(1);
        inputBus.assertContains(
            com.gtnewhorizons.horizonqa.api.gt.ItemMatcher.circuit(1));
        lcr.runRecipe(500);

        // Test circuit config 10
        inputBus.programmedCircuit(10);
        inputBus.assertContains(
            com.gtnewhorizons.horizonqa.api.gt.ItemMatcher.circuit(10));
        lcr.runRecipe(500);

        // Test circuit config 24 (max)
        inputBus.programmedCircuit(24);
        inputBus.assertContains(
            com.gtnewhorizons.horizonqa.api.gt.ItemMatcher.circuit(24));
        lcr.runRecipe(500);

        helper.succeed();
    }

    /**
     * Verify circuit is NOT consumed during recipe execution.
     * AutoOS assumes circuits are reusable and remain in their slot.
     */
    @GameTest(template = "lcr_basic", timeoutTicks = 300)
    public static void circuitNotConsumedByRecipe(GameTestHelper helper) {
        GTNHGameTestHelper gtnh = helper.gtnh();
        Multiblock lcr = gtnh.multiblock(at(1, 0, 0));

        lcr.assertFormed();
        lcr.fixMaintenance();

        Bus inputBus = lcr.inputBus(0);
        inputBus.programmedCircuit(5);

        // Run multiple recipes with the same circuit
        lcr.energyHatch(0).supply(128, 4, 500);

        for (int i = 0; i < 3; i++) {
            lcr.runRecipe(500);
            // Circuit should survive each recipe
            inputBus.assertContains(
                com.gtnewhorizons.horizonqa.api.gt.ItemMatcher.circuit(5));
        }

        helper.succeed();
    }
}
