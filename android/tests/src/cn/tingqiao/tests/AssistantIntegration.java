package cn.tingqiao.tests;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Intent;
import android.os.Bundle;
import android.os.SystemClock;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.TextView;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import org.json.JSONArray;
import org.json.JSONObject;

public class AssistantIntegration extends Instrumentation {
    @Override public void onCreate(Bundle args) { start(); }

    @Override public void onStart() {
        Bundle output = new Bundle();
        Activity activity = null;
        try {
            Intent intent = new Intent(Intent.ACTION_MAIN);
            intent.setClassName("cn.tingqiao.companion", "cn.tingqiao.companion.MainActivity");
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK);
            activity = startActivitySync(intent);
            final Activity screen = activity;
            waitForIdleSync();
            runOnMainSync(() -> {
                View root = screen.getWindow().getDecorView();
                require(find(root, "扫码连接 Wi-Fi 字幕") != null && find(root, "查找附近的 Mac") != null, "connection options");
                call(screen, "showBluetoothCaptions", null);
            });
            waitForIdleSync();
            runOnMainSync(() -> {
                View root = screen.getWindow().getDecorView();
                View answer = find(root, "帮我回答"), explain = find(root, "解释刚才");
                require(answer != null && explain != null && explain.getLeft() > answer.getRight(), "separate assistant buttons");
                View font = find(root, "字号"), latest = find(root, "回到最新 ↓");
                require(font != null && latest != null && latest.getLeft() > font.getRight(), "separate caption tools");
                require(answer.performClick(), "open answer overlay");
                require(find(root, "请先连接 Mac 的蓝牙字幕。") != null, "disconnected feedback");
                try {
                    Field request = screen.getClass().getDeclaredField("assistantRequestId");
                    request.setAccessible(true);
                    JSONObject reply = new JSONObject().put("id", request.get(screen)).put("state", "ready").put("text", "这是问答验证回复。").put("reasoning", "这是单独的思考内容。");
                    JSONObject update = new JSONObject().put("kind", "patch").put("captions", new JSONArray()).put("assistant", reply);
                    call(screen, "applyBluetoothUpdate", update);
                } catch (Exception error) { throw new AssertionError(error); }
                require(find(root, "这是问答验证回复。") != null, "reply displayed in overlay");
                View reasoning = find(root, "▸ 思考过程");
                require(reasoning != null && find(root, "这是单独的思考内容。") == null, "reasoning is collapsed by default");
                reasoning.performClick();
                require(find(root, "这是单独的思考内容。") != null, "reasoning can be expanded separately");
                reasoning.performClick();
                View handle = find(root, "拖动问答浮窗");
                require(handle != null, "drag handle");
                View panel = (View)((View)handle.getParent()).getParent();
                FrameLayout.LayoutParams params = (FrameLayout.LayoutParams)panel.getLayoutParams();
                int oldY = params.topMargin, oldHeight = params.height;
                drag(handle, 0, -44);
                require(params.topMargin < oldY, "floating reply moves");
                find(root, "缩小问答浮窗").performClick();
                require(params.height < oldHeight, "floating reply shrinks");
                find(root, "放大问答浮窗").performClick();
                require(params.height == oldHeight, "floating reply grows");
                find(root, "关闭问答浮窗").performClick();
                require(panel.getVisibility() == View.GONE, "floating reply closes");
            });
            output.putString("result", "PASS: Android connection layout, button spacing, assistant reply, drag, resize, dismiss");
            finish(Activity.RESULT_OK, output);
        } catch (Throwable error) {
            output.putString("result", "FAIL: " + error);
            finish(Activity.RESULT_CANCELED, output);
        }
    }

    private static View find(View node, String label) {
        if (node.getVisibility() != View.VISIBLE) return null;
        if (label.contentEquals(node.getContentDescription() == null ? "" : node.getContentDescription()) ||
            (node instanceof TextView && label.contentEquals(((TextView)node).getText()))) return node;
        if (node instanceof ViewGroup) {
            ViewGroup group = (ViewGroup)node;
            for (int index = 0; index < group.getChildCount(); index++) {
                View result = find(group.getChildAt(index), label);
                if (result != null) return result;
            }
        }
        return null;
    }

    private static void require(boolean condition, String description) {
        if (!condition) throw new AssertionError(description);
    }

    private static void call(Activity screen, String method, JSONObject arg) {
        try {
            Method target = arg == null ? screen.getClass().getDeclaredMethod(method) : screen.getClass().getDeclaredMethod(method, JSONObject.class);
            target.setAccessible(true);
            if (arg == null) target.invoke(screen); else target.invoke(screen, arg);
        } catch (Exception error) { throw new AssertionError(error); }
    }

    private static void drag(View view, int dx, int dy) {
        long now = SystemClock.uptimeMillis();
        int[] location = new int[2]; view.getLocationOnScreen(location);
        int x = location[0] + 15, y = location[1] + 15;
        int[] actions = {MotionEvent.ACTION_DOWN, MotionEvent.ACTION_MOVE, MotionEvent.ACTION_UP};
        for (int i = 0; i < actions.length; i++) {
            MotionEvent event = MotionEvent.obtain(now, now + i * 10, actions[i], x + (i == 0 ? 0 : dx), y + (i == 0 ? 0 : dy), 0);
            view.dispatchTouchEvent(event); event.recycle();
        }
    }
}
