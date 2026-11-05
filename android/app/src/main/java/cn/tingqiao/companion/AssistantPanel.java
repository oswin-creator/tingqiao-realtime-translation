package cn.tingqiao.companion;

import android.content.Context;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

/** An overlay inside the captions page. It never covers another app. */
final class AssistantPanel extends LinearLayout {
    private final FrameLayout host;
    private final TextView title;
    private final TextView reply;
    private final TextView reasoningToggle;
    private final TextView reasoningText;
    private final int accent = Color.rgb(91, 83, 210);
    private boolean waiting;

    AssistantPanel(FrameLayout host) {
        super(host.getContext());
        this.host = host;
        setOrientation(VERTICAL);
        setClickable(true);
        setPadding(dp(12), dp(7), dp(8), dp(5));
        GradientDrawable surface = new GradientDrawable();
        surface.setColor(Color.WHITE);
        surface.setCornerRadius(dp(16));
        surface.setStroke(dp(1), Color.rgb(222, 218, 251));
        setBackground(surface);
        setElevation(dp(12));
        setVisibility(GONE);

        LinearLayout header = new LinearLayout(getContext());
        header.setGravity(Gravity.CENTER_VERTICAL);
        title = label("会议助手", 14, accent);
        title.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        title.setContentDescription("拖动问答浮窗");
        title.setOnTouchListener(new PanelGesture(false));
        header.addView(title, new LinearLayout.LayoutParams(0, dp(36), 1));
        addControl(header, "−", "缩小问答浮窗", () -> resize(-32));
        addControl(header, "+", "放大问答浮窗", () -> resize(32));
        addControl(header, "×", "关闭问答浮窗", this::hide);
        addView(header, new LayoutParams(-1, dp(36)));

        ScrollView scroll = new ScrollView(getContext());
        LinearLayout content = new LinearLayout(getContext());
        content.setOrientation(VERTICAL);
        reasoningToggle = label("▸ 思考过程", 13, accent);
        reasoningToggle.setPadding(0, dp(5), dp(6), dp(5));
        reasoningToggle.setVisibility(GONE);
        reasoningText = label("", 13, Color.rgb(105, 108, 135));
        reasoningText.setPadding(0, 0, dp(7), dp(6));
        reasoningText.setVisibility(GONE);
        reasoningToggle.setOnClickListener(view -> {
            boolean expand = reasoningText.getVisibility() != VISIBLE;
            reasoningText.setVisibility(expand ? VISIBLE : GONE);
            reasoningToggle.setText(expand ? "▾ 思考过程" : "▸ 思考过程");
        });
        content.addView(reasoningToggle);
        content.addView(reasoningText);
        reply = label("", 15, Color.rgb(36, 43, 66));
        reply.setPadding(0, dp(6), dp(7), 0);
        reply.setLineSpacing(dp(4), 1);
        reply.setTextIsSelectable(true);
        reply.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        content.addView(reply);
        scroll.addView(content);
        addView(scroll, new LayoutParams(-1, 0, 1));

        TextView grip = label("◢", 15, accent);
        grip.setGravity(Gravity.CENTER);
        grip.setContentDescription("拖动调整问答浮窗大小");
        grip.setOnTouchListener(new PanelGesture(true));
        LayoutParams corner = new LayoutParams(dp(34), dp(25));
        corner.gravity = Gravity.END;
        addView(grip, corner);

        host.addView(this, new FrameLayout.LayoutParams(dp(320), dp(204), Gravity.TOP | Gravity.LEFT));
        host.addOnLayoutChangeListener((view, l, t, r, b, ol, ot, or, ob) -> {
            if (isShown() && (r - l != or - ol || b - t != ob - ot)) clamp();
        });
    }

    void open(String name) {
        if (getVisibility() != VISIBLE) {
            position(dp(14), Math.max(dp(8), host.getHeight() - dp(247)), dp(328), dp(206));
        }
        title.setText(name);
        setVisibility(VISIBLE);
        reasoningText.setVisibility(GONE);
        reasoningToggle.setText("▸ 思考过程");
        updateReasoning("");
        update("正在整理最近的对话…", true);
    }

    void update(String text, boolean pending) {
        waiting = pending;
        reply.setText(text);
    }

    void updateReasoning(String text) {
        if (!text.contentEquals(reasoningText.getText())) reasoningText.setText(text);
        reasoningToggle.setVisibility(text.isEmpty() ? GONE : VISIBLE);
        if (text.isEmpty()) reasoningText.setVisibility(GONE);
    }

    boolean busy() { return waiting && getVisibility() == VISIBLE; }
    private void hide() { setVisibility(GONE); waiting = false; }
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }

    private TextView label(String value, int size, int color) {
        TextView view = new TextView(getContext());
        view.setText(value);
        view.setTextSize(size);
        view.setTextColor(color);
        view.setGravity(Gravity.CENTER_VERTICAL);
        return view;
    }

    private void addControl(LinearLayout row, String value, String description, Runnable run) {
        TextView view = label(value, 19, accent);
        view.setGravity(Gravity.CENTER);
        view.setContentDescription(description);
        view.setOnClickListener(v -> run.run());
        row.addView(view, new LayoutParams(dp(34), dp(36)));
    }

    private void resize(int delta) {
        FrameLayout.LayoutParams p = (FrameLayout.LayoutParams) getLayoutParams();
        position(p.leftMargin, p.topMargin, p.width + dp(delta), p.height + dp(delta));
    }

    private void clamp() {
        FrameLayout.LayoutParams p = (FrameLayout.LayoutParams) getLayoutParams();
        position(p.leftMargin, p.topMargin, p.width, p.height);
    }

    private void position(int x, int y, int width, int height) {
        int maxWidth = host.getWidth(), maxHeight = host.getHeight();
        if (maxWidth <= 0 || maxHeight <= 0) return;
        width = Math.min(maxWidth, Math.max(dp(226), width));
        height = Math.min(maxHeight, Math.max(dp(144), height));
        FrameLayout.LayoutParams p = (FrameLayout.LayoutParams) getLayoutParams();
        p.leftMargin = Math.max(0, Math.min(x, maxWidth - width));
        p.topMargin = Math.max(0, Math.min(y, maxHeight - height));
        p.width = width;
        p.height = height;
        setLayoutParams(p);
    }

    private final class PanelGesture implements OnTouchListener {
        private final boolean resizing;
        private float downX, downY;
        private int startX, startY, startWidth, startHeight;

        PanelGesture(boolean resizing) { this.resizing = resizing; }

        @Override public boolean onTouch(View view, MotionEvent event) {
            switch (event.getActionMasked()) {
                case MotionEvent.ACTION_DOWN:
                    downX = event.getRawX(); downY = event.getRawY();
                    FrameLayout.LayoutParams p = (FrameLayout.LayoutParams) getLayoutParams();
                    startX = p.leftMargin; startY = p.topMargin; startWidth = p.width; startHeight = p.height;
                    return true;
                case MotionEvent.ACTION_MOVE:
                    int dx = Math.round(event.getRawX() - downX), dy = Math.round(event.getRawY() - downY);
                    if (resizing) position(startX, startY, startWidth + dx, startHeight + dy);
                    else position(startX + dx, startY + dy, startWidth, startHeight);
                    return true;
                case MotionEvent.ACTION_UP:
                    view.performClick();
                    return true;
                case MotionEvent.ACTION_CANCEL: return true;
                default: return false;
            }
        }
    }
}
