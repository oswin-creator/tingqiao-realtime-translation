package cn.tingqiao.companion;

import android.app.Activity;
import android.os.Bundle;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.view.View;
import android.view.WindowManager;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.webkit.WebResourceRequest;
import android.widget.*;
import java.net.URI;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothAdapter;
import android.content.Intent;
import java.util.*;
import org.json.*;
import java.util.regex.Pattern;

public class MainActivity extends Activity {
    private WebView web;
    private String origin;
    private String pairing;
    private BleCaptionClient ble;
    private boolean blePage=false, bleScanPage=false, followBle=true, bleOriginal=true;
    private int bleFont=24;
    private TextView bleStatus;
    private EditText bleCode;
    private LinearLayout bleDevices, bleRows, blePageLayout;
    private ScrollView bleScroll;
    private AssistantPanel assistantPanel;
    private String assistantRequestId = "";
    private final Set<String> foundAddresses=new HashSet<>();
    private final LinkedHashMap<String,JSONObject> bleCaptions=new LinkedHashMap<>();
    private final int INK = Color.rgb(36,43,66), MUTED = Color.rgb(133,140,164), ACCENT = Color.rgb(100,94,225), BG = Color.rgb(246,247,252);
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().setStatusBarColor(BG); getWindow().setNavigationBarColor(BG);
        getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);
        // Keep the display on while the companion is visible; release it when backgrounded.
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        pairing = getPreferences(MODE_PRIVATE).getString("pairing", "");
        ble=new BleCaptionClient(this,new BleCaptionClient.Listener(){
            public void status(String value){if(bleStatus!=null)bleStatus.setText(value);}
            public void found(BluetoothDevice device,String name){addBleDevice(device,name);}
            public void update(JSONObject value){applyBluetoothUpdate(value);}
            public void remember(BluetoothDevice device,JSONObject value){rememberComputer(device,value);}
            public void assistantUnavailable(String id){
                if(assistantPanel!=null && assistantRequestId.equals(id))assistantPanel.update("Mac 暂时无法接收问答，请确认听桥已更新。",false);
            }
        });
        showPairing();
    }
    @Override public void setContentView(View content) {
        FrameLayout safe=new FrameLayout(this);safe.setBackgroundColor(BG);
        safe.addView(content,new FrameLayout.LayoutParams(-1,-1));
        safe.setOnApplyWindowInsetsListener((v,insets)->{
            int left=insets.getSystemWindowInsetLeft(),top=insets.getSystemWindowInsetTop(),right=insets.getSystemWindowInsetRight(),bottom=insets.getSystemWindowInsetBottom();
            if(v.getPaddingLeft()!=left || v.getPaddingTop()!=top || v.getPaddingRight()!=right || v.getPaddingBottom()!=bottom)v.setPadding(left,top,right,bottom);
            return android.os.Build.VERSION.SDK_INT>=30?android.view.WindowInsets.CONSUMED:insets.consumeSystemWindowInsets();
        });
        super.setContentView(safe);safe.requestApplyInsets();
    }
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
    private TextView text(String value, int size, int color, boolean bold) {
        TextView view = new TextView(this); view.setText(value); view.setTextSize(size); view.setTextColor(color); view.setLineSpacing(dp(5),1);
        if(bold) view.setTypeface(Typeface.DEFAULT,Typeface.BOLD); return view;
    }
    private GradientDrawable rounded(int color, int radius) { GradientDrawable d = new GradientDrawable(); d.setColor(color); d.setCornerRadius(dp(radius)); return d; }
    private GradientDrawable outlined(int color, int radius, int stroke) {
        GradientDrawable shape = rounded(color, radius);
        shape.setStroke(dp(1), stroke);
        return shape;
    }
    private LinearLayout column(int horizontal, int vertical) {
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        layout.setPadding(dp(horizontal), dp(vertical), dp(horizontal), dp(vertical));
        return layout;
    }
    private LinearLayout card(LinearLayout page) {
        LinearLayout group = column(16, 15);
        group.setBackground(outlined(Color.WHITE, 17, Color.rgb(231, 229, 244)));
        page.addView(group, new LinearLayout.LayoutParams(-1, -2));
        return group;
    }
    private void identity(LinearLayout page, String title, String subtitle) {
        LinearLayout heading = new LinearLayout(this);
        heading.setGravity(android.view.Gravity.CENTER_VERTICAL);
        TextView mark = text("听", 21, Color.WHITE, true);
        mark.setGravity(android.view.Gravity.CENTER);
        mark.setBackground(rounded(ACCENT, 13));
        LinearLayout.LayoutParams icon = new LinearLayout.LayoutParams(dp(44), dp(44));
        icon.rightMargin = dp(11);
        heading.addView(mark, icon);
        LinearLayout words = column(0, 0);
        words.addView(text(title, 22, INK, true));
        words.addView(text(subtitle, 12, MUTED, false));
        heading.addView(words, new LinearLayout.LayoutParams(0, -2, 1));
        page.addView(heading);
    }
    private void spacedAction(LinearLayout group, Button button, int gap) {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-1, dp(48));
        params.topMargin = dp(gap);
        group.addView(button, params);
    }
    private void showPairing() {
        getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
        if(ble!=null)ble.disconnect();blePage=false;bleScanPage=false;bleStatus=null;assistantPanel=null;assistantRequestId="";
        if(web != null) { web.destroy(); web = null; }
        ScrollView scroll = new ScrollView(this); scroll.setBackgroundColor(BG);
        LinearLayout box = column(20, 28); scroll.addView(box);
        identity(box, "听桥 · 随身字幕", "连接 Mac，查看字幕和会议问答");
        addSpace(box,22);
        LinearLayout wifi = card(box);
        wifi.addView(text("Wi-Fi 连接", 17, INK, true));
        wifi.addView(text("手机和 Mac 连到同一个网络。", 12, MUTED, false));
        Button scanQr=action("扫码连接 Wi-Fi 字幕");
        scanQr.setTextColor(Color.WHITE);scanQr.setBackground(rounded(ACCENT,12));
        spacedAction(wifi, scanQr, 12);
        scanQr.setOnClickListener(v->startActivityForResult(new Intent(this,ScanActivity.class),43));
        addSpace(wifi,14);wifi.addView(text("也可粘贴 Mac 上的完整配对链接",12,MUTED,false));
        addSpace(wifi,6);
        EditText address = new EditText(this); address.setSingleLine(false); address.setMinLines(2); address.setTextSize(13); address.setTextColor(INK); address.setPadding(dp(12),dp(9),dp(12),dp(9)); address.setHint("http://192.168.x.x:端口/#配对码"); address.setText(pairing); address.setBackground(outlined(BG,10,Color.rgb(231,229,244))); address.setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_VARIATION_URI | android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS); wifi.addView(address,new LinearLayout.LayoutParams(-1,-2));
        Button connect = action("用链接连接"); spacedAction(wifi,connect,8);
        connect.setOnClickListener(new View.OnClickListener(){ @Override public void onClick(View v) { String value = address.getText().toString().trim(); if(!valid(value)) { Toast.makeText(MainActivity.this,"请粘贴完整的局域网配对链接，包含 # 后的配对码",Toast.LENGTH_LONG).show(); return; } pairing=value; getPreferences(MODE_PRIVATE).edit().putString("pairing",pairing).apply(); showCaptions(value); }});
        addSpace(box,12);
        LinearLayout bluetoothCard = card(box);
        bluetoothCard.addView(text("蓝牙连接",17,INK,true));
        bluetoothCard.addView(text("无需 Wi-Fi，可直接连接附近的 Mac。",12,MUTED,false));
        Button bluetooth=action("查找附近的 Mac");spacedAction(bluetoothCard,bluetooth,10);
        bluetooth.setOnClickListener(v->showBluetooth());
        addSpace(box,17); box.addView(text("在 Mac 的「手机字幕」里打开对应连接方式。请勿分享配对链接或配对码。",12,MUTED,false));
        setContentView(scroll);
    }
    private void addSpace(LinearLayout box,int value) { View view = new View(this); box.addView(view,new LinearLayout.LayoutParams(1,dp(value))); }
    private boolean valid(String value) { return PairingLink.valid(value); }
    private void showCaptions(String value) {
        try { URI uri = new URI(value); origin = uri.getScheme()+"://"+uri.getHost()+":"+uri.getPort(); }catch(Exception error){return;}
        web = new WebView(this); web.setBackgroundColor(BG);
        web.getSettings().setJavaScriptEnabled(true); web.getSettings().setDomStorageEnabled(true);
        web.getSettings().setAllowFileAccess(false); web.getSettings().setAllowContentAccess(false);
        web.getSettings().setMixedContentMode(android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        web.setWebViewClient(new WebViewClient(){
            @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                try { URI uri = new URI(request.getUrl().toString()); return !(uri.getScheme()+"://"+uri.getHost()+":"+uri.getPort()).equals(origin); } catch(Exception error){return true;}
            }
        });
        setContentView(web); web.loadUrl(value);
    }
    private Button action(String value){Button b=new Button(this);b.setText(value);b.setAllCaps(false);b.setTextColor(ACCENT);b.setTextSize(14);b.setMinWidth(0);b.setMinimumWidth(0);b.setPadding(dp(5),0,dp(5),0);b.setBackground(outlined(Color.rgb(248,247,255),11,Color.rgb(229,225,250)));b.setElevation(0);b.setStateListAnimator(null);return b;}
    private void showBluetooth(){
        getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
        if(web!=null){web.destroy();web=null;}blePage=false;bleScanPage=true;foundAddresses.clear();
        ScrollView scroll=new ScrollView(this);scroll.setBackgroundColor(BG);
        LinearLayout box=column(20,24);scroll.addView(box);
        identity(box,"蓝牙连接","无需 Wi-Fi，直接连接附近的 Mac");
        Button back=action("‹ 返回连接方式");back.setOnClickListener(v->showPairing());spacedAction(box,back,12);
        addSpace(box,15);
        addSavedComputers(box);
        LinearLayout pairingCard = card(box);
        pairingCard.addView(text("配对新电脑",16,INK,true));
        pairingCard.addView(text("在 Mac 开启蓝牙字幕，输入显示的六位配对码。",12,MUTED,false));
        addSpace(pairingCard,10);
        String savedCode=getPreferences(MODE_PRIVATE).getString("bluetooth_pairing_code","");
        LinearLayout codeRow=new LinearLayout(this);codeRow.setOrientation(LinearLayout.HORIZONTAL);
        bleCode=new EditText(this);bleCode.setHint("六位配对码");bleCode.setContentDescription("电脑上的六位配对码");bleCode.setTextSize(22);bleCode.setSingleLine(true);bleCode.setInputType(android.text.InputType.TYPE_CLASS_NUMBER);bleCode.setFilters(new android.text.InputFilter[]{new android.text.InputFilter.LengthFilter(6)});bleCode.setBackground(rounded(Color.WHITE,12));bleCode.setPadding(dp(16),dp(14),dp(16),dp(14));bleCode.setText(savedCode);
        LinearLayout.LayoutParams codeParams=new LinearLayout.LayoutParams(0,dp(58),1);codeParams.rightMargin=dp(10);codeRow.addView(bleCode,codeParams);
        Button saveCode=action("保存配对码");codeRow.addView(saveCode,new LinearLayout.LayoutParams(dp(108),dp(58)));pairingCard.addView(codeRow,new LinearLayout.LayoutParams(-1,-2));
        addSpace(pairingCard,8);TextView savedHint=text(savedCode.isEmpty()?"仅保存在这台手机，下次进入时自动填入。":"已填入上次保存的配对码。",11,MUTED,false);pairingCard.addView(savedHint);
        saveCode.setOnClickListener(v->{
            String value=bleCode.getText().toString().trim();
            if(!value.matches("[0-9]{6}")){bleCode.setError("请输入六位配对码后再保存");return;}
            getPreferences(MODE_PRIVATE).edit().putString("bluetooth_pairing_code",value).apply();
            savedHint.setText("配对码已保存在本机，下次会自动填入。");
        });

        addSpace(box,12);LinearLayout nearby=card(box);nearby.addView(text("附近的 Mac",16,INK,true));
        bleStatus=text("准备扫描…",12,MUTED,false);nearby.addView(bleStatus);
        bleDevices=column(0,0);nearby.addView(bleDevices);
        Button again=action("重新扫描附近的听桥");again.setOnClickListener(v->startBleScan());spacedAction(nearby,again,9);
        addSpace(box,24);box.addView(text("首次连接可能出现系统蓝牙配对提示，请在两端允许。连接后无需 Wi-Fi。字幕页面保持亮屏；返回本页可以更换电脑。",12,MUTED,false));
        setContentView(scroll);startBleScan();
    }
    private JSONArray savedComputers(){try{return new JSONArray(getPreferences(MODE_PRIVATE).getString("paired_computers","[]"));}catch(Exception e){return new JSONArray();}}
    private JSONObject savedComputer(String address){JSONArray list=savedComputers();for(int i=0;i<list.length();i++){JSONObject p=list.optJSONObject(i);if(p!=null && address.equals(p.optString("address")))return p;}return null;}
    private void rememberComputer(BluetoothDevice device,JSONObject update){
        String id=update.optString("computerID",""),token=update.optString("pairingToken","");if(id.isEmpty() || !token.matches("[A-Za-z0-9_-]{16}"))return;
        try{JSONArray old=savedComputers(),next=new JSONArray();JSONObject peer=new JSONObject();peer.put("id",id);peer.put("token",token);peer.put("address",device.getAddress());peer.put("name",update.optString("computerName","听桥 Mac"));next.put(peer);
            for(int i=0;i<old.length() && next.length()<20;i++){JSONObject p=old.optJSONObject(i);if(p!=null && !id.equals(p.optString("id")) && !device.getAddress().equals(p.optString("address")))next.put(p);}
            getPreferences(MODE_PRIVATE).edit().putString("paired_computers",next.toString()).apply();
        }catch(Exception ignored){}
    }
    private void addSavedComputers(LinearLayout box){
        JSONArray list=savedComputers();if(list.length()==0)return;LinearLayout saved=card(box);saved.addView(text("已配对的电脑",16,INK,true));
        for(int i=0;i<list.length();i++){JSONObject peer=list.optJSONObject(i);if(peer==null)continue;LinearLayout row=new LinearLayout(this);
            Button connect=action(peer.optString("name","听桥 Mac")+" · 连接");LinearLayout.LayoutParams left=new LinearLayout.LayoutParams(0,dp(48),1);left.rightMargin=dp(7);row.addView(connect,left);connect.setOnClickListener(v->{showBluetoothCaptions();ble.connectSaved(peer.optString("address"),peer.optString("token"));});
            Button forget=action("忘记");row.addView(forget,new LinearLayout.LayoutParams(dp(64),dp(48)));forget.setOnClickListener(v->{JSONArray keep=new JSONArray();for(int j=0;j<list.length();j++){JSONObject p=list.optJSONObject(j);if(p!=null && !peer.optString("id").equals(p.optString("id")))keep.put(p);}getPreferences(MODE_PRIVATE).edit().putString("paired_computers",keep.toString()).apply();showBluetooth();});addSpace(saved,8);saved.addView(row);
        }addSpace(box,12);
    }
    private void startBleScan(){
        foundAddresses.clear();if(bleDevices!=null)bleDevices.removeAllViews();
        if(!ble.permitted()){requestPermissions(ble.permissions(),41);return;}
        if(!ble.enabled()){try{startActivityForResult(new Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE),42);}catch(Exception e){bleStatus.setText("请在手机设置中打开蓝牙。");}return;}
        ble.scan();
    }
    @Override public void onRequestPermissionsResult(int request,String[] permissions,int[] grants){
        super.onRequestPermissionsResult(request,permissions,grants);
        if(request==41 && bleScanPage){if(ble.permitted())startBleScan();else bleStatus.setText("蓝牙扫描需要附近设备权限，可在系统设置中允许后重新扫描。");}
    }
    @Override protected void onActivityResult(int request,int result,Intent data){super.onActivityResult(request,result,data);if(request==43 && result==RESULT_OK && data!=null){String value=data.getStringExtra("pairing");if(value!=null && valid(value)){pairing=value;getPreferences(MODE_PRIVATE).edit().putString("pairing",value).apply();showCaptions(value);}return;}if(request==42 && bleScanPage){if(ble.enabled())startBleScan();else bleStatus.setText("手机蓝牙未开启。");}}
    private void addBleDevice(BluetoothDevice device,String name){
        if(!bleScanPage || !foundAddresses.add(device.getAddress()))return;
        Button connect=action(name+" · 点击连接");connect.setBackground(rounded(Color.WHITE,12));
        LinearLayout.LayoutParams params=new LinearLayout.LayoutParams(-1,dp(58));params.topMargin=dp(12);bleDevices.addView(connect,params);
        connect.setOnClickListener(v->{JSONObject saved=savedComputer(device.getAddress());if(saved!=null){showBluetoothCaptions();ble.connectSaved(device.getAddress(),saved.optString("token"));return;}String code=bleCode.getText().toString().trim();if(!code.matches("[0-9]{6}")){bleCode.setError("请输入电脑显示的六位配对码");return;}showBluetoothCaptions();ble.connect(device,code);});
        bleStatus.setText("已找到听桥，输入配对码后点击连接。");
    }
    private static final class CaptionLayout extends LinearLayout {
        CaptionLayout(android.content.Context context){super(context);setOrientation(VERTICAL);setFocusableInTouchMode(true);setDescendantFocusability(FOCUS_BEFORE_DESCENDANTS);}
        // The subtitle list scrolls itself; focusing a sentence must not pan the whole window.
        @Override public boolean requestChildRectangleOnScreen(View child,android.graphics.Rect rectangle,boolean immediate){return false;}
    }
    private void showBluetoothCaptions(){
        if(getCurrentFocus()!=null)((android.view.inputmethod.InputMethodManager)getSystemService(INPUT_METHOD_SERVICE)).hideSoftInputFromWindow(getCurrentFocus().getWindowToken(),0);
        getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING);
        bleScanPage=false;blePage=true;followBle=true;bleCaptions.clear();
        LinearLayout page=new CaptionLayout(this);blePageLayout=page;page.setBackgroundColor(BG);
        LinearLayout header=column(16,11);header.setBackgroundColor(BG);header.setElevation(dp(2));
        LinearLayout heading = new LinearLayout(this);heading.setGravity(android.view.Gravity.CENTER_VERTICAL);
        LinearLayout title = column(0,0);identity(title,"听桥 · 随身字幕","蓝牙连接");heading.addView(title,new LinearLayout.LayoutParams(0,-2,1));
        Button back=action("更换电脑");back.setTextSize(12);back.setOnClickListener(v->showBluetooth());heading.addView(back,new LinearLayout.LayoutParams(dp(78),dp(40)));
        header.addView(heading);addSpace(header,8);bleStatus=text("正在连接…",12,MUTED,false);header.addView(bleStatus);
        addSpace(header,9);header.addView(text("会议助手",11,MUTED,true));addSpace(header,4);
        LinearLayout actions=new LinearLayout(this);
        Button original=action("原文开关");original.setOnClickListener(v->{bleOriginal=!bleOriginal;renderBluetooth();});actions.addView(original);
        Button font=action("字号");font.setOnClickListener(v->{bleFont=bleFont==24?30:24;renderBluetooth();});actions.addView(font);
        Button latest=action("回到最新 ↓");latest.setOnClickListener(v->{followBle=true;bleScroll.post(()->bleScroll.scrollTo(0,Math.max(0,bleRows.getHeight()-bleScroll.getHeight())));});actions.addView(latest);
        for(int i=0;i<actions.getChildCount();i++){
            Button button=(Button)actions.getChildAt(i);button.setTextSize(12);
            LinearLayout.LayoutParams params=new LinearLayout.LayoutParams(0,dp(42),1);
            if(i>0)params.leftMargin=dp(7);
            button.setLayoutParams(params);
        }
        LinearLayout assistantActions = new LinearLayout(this);
        Button answer = action("帮我回答"), explain = action("解释刚才");
        answer.setBackground(rounded(Color.rgb(235, 232, 255), 10));
        explain.setBackground(rounded(Color.rgb(242, 240, 253), 10));
        LinearLayout.LayoutParams left = new LinearLayout.LayoutParams(0, dp(44), 1); left.rightMargin = dp(8);
        assistantActions.addView(answer, left);
        assistantActions.addView(explain, new LinearLayout.LayoutParams(0, dp(44), 1));
        header.addView(assistantActions);
        addSpace(header,9);header.addView(actions);page.addView(header,new LinearLayout.LayoutParams(-1,-2));
        answer.setOnClickListener(v -> askBluetoothAssistant(true));
        explain.setOnClickListener(v -> askBluetoothAssistant(false));
        bleScroll=new ScrollView(this);bleScroll.setFillViewport(true);bleScroll.setFocusableInTouchMode(true);bleScroll.setDescendantFocusability(android.view.ViewGroup.FOCUS_BEFORE_DESCENDANTS);bleRows=new LinearLayout(this);bleRows.setOrientation(1);bleRows.setPadding(dp(16),dp(8),dp(16),dp(24));bleScroll.addView(bleRows);
        bleScroll.setOnScrollChangeListener((View v,int x,int y,int oldX,int oldY)->{if(bleRows!=null)followBle=bleRows.getHeight()-(y+bleScroll.getHeight())<dp(100);});
        page.addView(bleScroll,new LinearLayout.LayoutParams(-1,0,1));
        FrameLayout overlayHost = new FrameLayout(this);
        overlayHost.addView(page, new FrameLayout.LayoutParams(-1, -1));
        assistantPanel = new AssistantPanel(overlayHost);
        assistantRequestId = "";
        setContentView(overlayHost);renderBluetooth();
    }

    private void askBluetoothAssistant(boolean answer) {
        if (assistantPanel == null || assistantPanel.busy()) return;
        assistantPanel.open(answer ? "帮我回答" : "解释刚才");
        String id = UUID.randomUUID().toString().replace("-", "").substring(0, 12);
        assistantRequestId = id;
        if (!ble.askAssistant(answer, id)) {
            assistantPanel.update("请先连接 Mac 的蓝牙字幕。", false);
            return;
        }
        assistantPanel.postDelayed(() -> {
            if (assistantPanel != null && id.equals(assistantRequestId) && assistantPanel.busy()) {
                assistantPanel.update("暂未收到回复，请检查 Mac 连接。", false);
            }
        }, 60000);
    }
    private void applyBluetoothUpdate(JSONObject update){
        if(!blePage)return;
        try{
            String kind=update.getString("kind");if("snapshot".equals(kind))bleCaptions.clear();else if(!"patch".equals(kind))throw new JSONException("invalid update");
            JSONArray removed=update.optJSONArray("removed");if(removed!=null)for(int i=0;i<removed.length();i++)bleCaptions.remove(removed.getString(i));
            JSONArray captions=update.getJSONArray("captions");for(int i=0;i<captions.length();i++){JSONObject c=captions.getJSONObject(i);bleCaptions.put(c.getString("id"),c);}
            if(bleCaptions.size()>80){ArrayList<JSONObject> ordered=orderedCaptions();while(ordered.size()>80)bleCaptions.remove(ordered.remove(0).getString("id"));}
            bleStatus.setText("蓝牙已连接 · "+update.optString("status","等待字幕"));
            if ("snapshot".equals(kind) || captions.length() > 0 || (removed != null && removed.length() > 0)) renderBluetooth();
            JSONObject assistant = update.optJSONObject("assistant");
            if (assistant != null && assistantPanel != null && assistantRequestId.equals(assistant.optString("id"))) {
                assistantPanel.updateReasoning(assistant.optString("reasoning", ""));
                assistantPanel.update(assistant.optString("text"), "waiting".equals(assistant.optString("state")));
            }
        }catch(JSONException error){bleStatus.setText("收到的字幕格式不完整，正在等待补齐。");}
    }
    private ArrayList<JSONObject> orderedCaptions(){ArrayList<JSONObject> list=new ArrayList<>(bleCaptions.values());Collections.sort(list,(a,b)->Double.compare(a.optDouble("date"),b.optDouble("date")));return list;}
    private void renderBluetooth(){
        if(!blePage || bleRows==null)return;boolean follow=followBle;int previousY=bleScroll.getScrollY();blePageLayout.requestFocus();bleRows.removeAllViews();
        for(JSONObject c:orderedCaptions()){
            LinearLayout row=new LinearLayout(this);row.setOrientation(1);row.setPadding(dp(16),dp(14),dp(16),dp(16));row.setBackground(rounded(Color.WHITE,14));
            Date date=new Date((long)((c.optDouble("date")+978307200)*1000));row.addView(text(android.text.format.DateFormat.format("HH:mm:ss",date).toString(),10,MUTED,false));
            if(bleOriginal || c.optBoolean("isDraft")){addSpace(row,7);row.addView(text(c.optString("original"),14,MUTED,false));}
            addSpace(row,7);String translated=c.optString("translated");TextView zh=text(c.optBoolean("isDraft")?"正在听 · 确认整句后翻译":translated.isEmpty()?"正在翻译…":translated,bleFont,INK,false);zh.setTextIsSelectable(true);row.addView(zh);
            LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);lp.bottomMargin=dp(12);bleRows.addView(row,lp);
        }
        if(bleCaptions.isEmpty()){TextView empty=text("等待下一句对话…",18,MUTED,false);empty.setPadding(dp(16),dp(70),dp(16),dp(70));bleRows.addView(empty);}
        bleScroll.post(()->{if(follow)bleScroll.scrollTo(0,Math.max(0,bleRows.getHeight()-bleScroll.getHeight()));else bleScroll.scrollTo(0,previousY);followBle=follow;});
    }
    @Override public void onBackPressed(){ if(web!=null || blePage || bleScanPage)showPairing();else super.onBackPressed(); }
    @Override protected void onPause(){super.onPause();if(web!=null)web.onPause();}
    @Override protected void onResume(){super.onResume();if(web!=null)web.onResume();if(ble!=null && blePage)ble.resume();}
    @Override protected void onDestroy(){if(web!=null)web.destroy();if(ble!=null)ble.destroy();super.onDestroy();}
}
