package com.henrypann.jinbao365.debug;

import android.accessibilityservice.AccessibilityServiceInfo;
import android.app.Activity;
import android.app.Instrumentation;
import android.app.UiAutomation;
import android.graphics.Rect;
import android.os.Bundle;
import android.os.SystemClock;
import android.view.InputDevice;
import android.view.MotionEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import java.util.ArrayList;
import java.util.List;

/** Platform-only driver, instrumenting the test APK itself without restarting the viewer. */
public final class SmokeGestureInstrumentation extends Instrumentation {
    private String operation = "state";
    private String stage = "create";

    @Override public void onCreate(Bundle arguments) {
        super.onCreate(arguments);
        if (arguments != null && arguments.getString("operation") != null) {
            operation = arguments.getString("operation");
        }
        start();
    }

    @Override public void onStart() {
        Bundle result = new Bundle();
        try {
            stage = "automation";
            UiAutomation automation = getUiAutomation();
            stage = "service_flags";
            AccessibilityServiceInfo info = automation.getServiceInfo();
            require(info != null);
            info.flags |= AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS
                    | AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS;
            automation.setServiceInfo(info);
            stage = "root";
            AccessibilityNodeInfo root = null;
            for (int attempt = 0; attempt < 30; attempt++) {
                root = automation.getRootInActiveWindow();
                if (root != null) break;
                SystemClock.sleep(100);
            }
            require(root != null);
            stage = "package";
            require("com.henrypann.jinbao365".contentEquals(root.getPackageName() == null ? "" : root.getPackageName()));
            stage = "tree";
            List<AccessibilityNodeInfo> nodes = new ArrayList<>();
            visit(root, nodes, 0);
            StringBuilder tags = new StringBuilder();
            StringBuilder descriptions = new StringBuilder();
            boolean viewer = false;
            for (AccessibilityNodeInfo node : nodes) {
                String id = node.getViewIdResourceName();
                if (id != null && id.contains("photoViewer")) {
                    viewer = true;
                    append(tags, id);
                }
                CharSequence description = node.getContentDescription();
                if (description != null && ("原图".contentEquals(description)
                        || "对方原图".contentEquals(description) || "缩略图".contentEquals(description))) {
                    append(descriptions, description.toString());
                }
            }
            result.putString("viewerTags", tags.toString());
            result.putString("bitmapDescription", descriptions.toString());
            if (!"state".equals(operation)) {
                stage = "operation";
                require("pinch_out".equals(operation) || "pinch_in".equals(operation));
                stage = "viewer_guard";
                require(viewer);
                Rect bounds = new Rect();
                root.getBoundsInScreen(bounds);
                float x = bounds.exactCenterX();
                float y = bounds.exactCenterY();
                float small = bounds.width() * .07f;
                float large = bounds.width() * .38f;
                float from = "pinch_out".equals(operation) ? small : large;
                float to = "pinch_out".equals(operation) ? large : small;
                long downTime = SystemClock.uptimeMillis();
                inject(automation, downTime, MotionEvent.ACTION_DOWN, 1, from, x, y);
                inject(automation, downTime, MotionEvent.ACTION_POINTER_DOWN
                        | (1 << MotionEvent.ACTION_POINTER_INDEX_SHIFT), 2, from, x, y);
                for (int step = 0; step < 30; step++) {
                    SystemClock.sleep(16);
                    inject(automation, downTime, MotionEvent.ACTION_MOVE, 2,
                            from + (to - from) * (step + 1) / 30f, x, y);
                }
                inject(automation, downTime, MotionEvent.ACTION_POINTER_UP
                        | (1 << MotionEvent.ACTION_POINTER_INDEX_SHIFT), 2, to, x, y);
                inject(automation, downTime, MotionEvent.ACTION_UP, 1, to, x, y);
                SystemClock.sleep(200);
            }
            result.putString("operation", operation);
            result.putString("status", "ok");
            result.putString("stage", "complete");
            finish(Activity.RESULT_OK, result);
        } catch (Throwable failure) {
            // Linkage errors are included, but messages, causes and arbitrary screen text are not.
            result.putString("stage", stage);
            result.putString("exception", failure.getClass().getSimpleName());
            result.putString("status", "driver_failed");
            finish(Activity.RESULT_CANCELED, result);
        }
    }

    private void inject(UiAutomation automation, long downTime, int action, int count,
                        float span, float x, float y) {
        switch (action & MotionEvent.ACTION_MASK) {
            case MotionEvent.ACTION_DOWN: stage = "inject_down"; break;
            case MotionEvent.ACTION_POINTER_DOWN: stage = "inject_second_down"; break;
            case MotionEvent.ACTION_MOVE: stage = "inject_move"; break;
            case MotionEvent.ACTION_POINTER_UP: stage = "inject_second_up"; break;
            default: stage = "inject_up";
        }
        MotionEvent.PointerProperties[] properties = new MotionEvent.PointerProperties[count];
        MotionEvent.PointerCoords[] coordinates = new MotionEvent.PointerCoords[count];
        for (int index = 0; index < count; index++) {
            properties[index] = new MotionEvent.PointerProperties();
            properties[index].id = index;
            properties[index].toolType = MotionEvent.TOOL_TYPE_FINGER;
            coordinates[index] = new MotionEvent.PointerCoords();
            coordinates[index].x = x + (index == 0 ? -span : span);
            coordinates[index].y = y;
            coordinates[index].pressure = 1f;
            coordinates[index].size = .05f;
        }
        MotionEvent event = MotionEvent.obtain(downTime, SystemClock.uptimeMillis(), action,
                count, properties, coordinates, 0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0);
        try { require(automation.injectInputEvent(event, true)); }
        finally { event.recycle(); }
    }

    private static void visit(AccessibilityNodeInfo node, List<AccessibilityNodeInfo> nodes, int depth) {
        require(depth <= 100 && nodes.size() < 4096);
        nodes.add(node);
        for (int index = 0; index < node.getChildCount(); index++) {
            AccessibilityNodeInfo child = node.getChild(index);
            if (child != null) visit(child, nodes, depth + 1);
        }
    }

    private static void append(StringBuilder builder, String value) {
        if (builder.length() > 0) builder.append(',');
        builder.append(value);
    }

    private static void require(boolean condition) {
        if (!condition) throw new IllegalStateException();
    }
}
