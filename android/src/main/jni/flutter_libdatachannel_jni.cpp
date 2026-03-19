#include <jni.h>
#include <string>
#include <mutex>
#include <android/log.h>

#include "flutter_libdatachannel.h"

#define LOG_TAG "FlutterLibdatachannel"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

static JavaVM* g_jvm = nullptr;
static jobject g_event_handler = nullptr;
static jmethodID g_on_event_method = nullptr;
static jmethodID g_on_binary_event_method = nullptr;
static std::mutex g_jni_mutex;

extern "C" {

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved) {
    g_jvm = vm;
    ldc_init();
    return JNI_VERSION_1_6;
}

JNIEXPORT void JNICALL JNI_OnUnload(JavaVM* vm, void* reserved) {
    ldc_cleanup();
    g_jvm = nullptr;
}

static JNIEnv* GetEnv() {
    JNIEnv* env = nullptr;
    if (g_jvm) {
        g_jvm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6);
        if (!env) {
            g_jvm->AttachCurrentThread(&env, nullptr);
        }
    }
    return env;
}

JNIEXPORT void JNICALL
Java_com_example_flutter_1libdatachannel_FlutterLibdatachannelPlugin_nativeSetEventHandler(
    JNIEnv* env, jobject thiz, jobject handler) {
    std::lock_guard<std::mutex> lock(g_jni_mutex);

    if (g_event_handler) {
        env->DeleteGlobalRef(g_event_handler);
        g_event_handler = nullptr;
    }

    if (handler) {
        g_event_handler = env->NewGlobalRef(handler);
        jclass cls = env->GetObjectClass(handler);
        g_on_event_method = env->GetMethodID(cls, "onEvent", "(Ljava/lang/String;)V");
        g_on_binary_event_method = env->GetMethodID(cls, "onBinaryEvent", "(I[B)V");

        ldc_set_event_callback([](const char* event_json, void* user_data) {
            JNIEnv* env = GetEnv();
            if (!env) return;
            std::lock_guard<std::mutex> lock(g_jni_mutex);
            if (g_event_handler && g_on_event_method) {
                jstring json = env->NewStringUTF(event_json);
                env->CallVoidMethod(g_event_handler, g_on_event_method, json);
                env->DeleteLocalRef(json);
            }
        }, nullptr);

        ldc_set_binary_event_callback([](int tr_id, const uint8_t* data, int size, void* user_data) {
            JNIEnv* env = GetEnv();
            if (!env) return;
            std::lock_guard<std::mutex> lock(g_jni_mutex);
            if (g_event_handler && g_on_binary_event_method) {
                jbyteArray arr = env->NewByteArray(size);
                env->SetByteArrayRegion(arr, 0, size, reinterpret_cast<const jbyte*>(data));
                env->CallVoidMethod(g_event_handler, g_on_binary_event_method, (jint)tr_id, arr);
                env->DeleteLocalRef(arr);
            }
        }, nullptr);
    } else {
        ldc_set_event_callback(nullptr, nullptr);
        ldc_set_binary_event_callback(nullptr, nullptr);
    }
}

JNIEXPORT jint JNICALL
Java_com_example_flutter_1libdatachannel_FlutterLibdatachannelPlugin_nativeCreatePeerConnection(
    JNIEnv* env, jobject thiz, jstring ice_servers_json) {
    const char* json = ice_servers_json ? env->GetStringUTFChars(ice_servers_json, nullptr) : nullptr;
    int result = ldc_create_peer_connection(json);
    if (json) env->ReleaseStringUTFChars(ice_servers_json, json);
    return result;
}

JNIEXPORT void JNICALL
Java_com_example_flutter_1libdatachannel_FlutterLibdatachannelPlugin_nativeClosePeerConnection(
    JNIEnv* env, jobject thiz, jint pc_id) {
    ldc_close_peer_connection(pc_id);
}

JNIEXPORT void JNICALL
Java_com_example_flutter_1libdatachannel_FlutterLibdatachannelPlugin_nativeDeletePeerConnection(
    JNIEnv* env, jobject thiz, jint pc_id) {
    ldc_delete_peer_connection(pc_id);
}

JNIEXPORT jint JNICALL
Java_com_example_flutter_1libdatachannel_FlutterLibdatachannelPlugin_nativeSetLocalDescription(
    JNIEnv* env, jobject thiz, jint pc_id, jstring type) {
    const char* t = type ? env->GetStringUTFChars(type, nullptr) : nullptr;
    int result = ldc_set_local_description(pc_id, t);
    if (t) env->ReleaseStringUTFChars(type, t);
    return result;
}

JNIEXPORT jint JNICALL
Java_com_example_flutter_1libdatachannel_FlutterLibdatachannelPlugin_nativeSetRemoteDescription(
    JNIEnv* env, jobject thiz, jint pc_id, jstring sdp, jstring type) {
    const char* s = sdp ? env->GetStringUTFChars(sdp, nullptr) : nullptr;
    const char* t = type ? env->GetStringUTFChars(type, nullptr) : nullptr;
    int result = ldc_set_remote_description(pc_id, s, t);
    if (s) env->ReleaseStringUTFChars(sdp, s);
    if (t) env->ReleaseStringUTFChars(type, t);
    return result;
}

JNIEXPORT jint JNICALL
Java_com_example_flutter_1libdatachannel_FlutterLibdatachannelPlugin_nativeAddRemoteCandidate(
    JNIEnv* env, jobject thiz, jint pc_id, jstring candidate, jstring mid) {
    const char* c = candidate ? env->GetStringUTFChars(candidate, nullptr) : nullptr;
    const char* m = mid ? env->GetStringUTFChars(mid, nullptr) : nullptr;
    int result = ldc_add_remote_candidate(pc_id, c, m);
    if (c) env->ReleaseStringUTFChars(candidate, c);
    if (m) env->ReleaseStringUTFChars(mid, m);
    return result;
}

JNIEXPORT jstring JNICALL
Java_com_example_flutter_1libdatachannel_FlutterLibdatachannelPlugin_nativeGetLocalDescription(
    JNIEnv* env, jobject thiz, jint pc_id) {
    char* sdp = ldc_get_local_description(pc_id);
    jstring result = sdp ? env->NewStringUTF(sdp) : nullptr;
    if (sdp) ldc_free(sdp);
    return result;
}

JNIEXPORT jstring JNICALL
Java_com_example_flutter_1libdatachannel_FlutterLibdatachannelPlugin_nativeGetLocalDescriptionType(
    JNIEnv* env, jobject thiz, jint pc_id) {
    char* type = ldc_get_local_description_type(pc_id);
    jstring result = type ? env->NewStringUTF(type) : nullptr;
    if (type) ldc_free(type);
    return result;
}

JNIEXPORT jstring JNICALL
Java_com_example_flutter_1libdatachannel_FlutterLibdatachannelPlugin_nativeGetRemoteDescription(
    JNIEnv* env, jobject thiz, jint pc_id) {
    char* sdp = ldc_get_remote_description(pc_id);
    jstring result = sdp ? env->NewStringUTF(sdp) : nullptr;
    if (sdp) ldc_free(sdp);
    return result;
}

JNIEXPORT jstring JNICALL
Java_com_example_flutter_1libdatachannel_FlutterLibdatachannelPlugin_nativeGetRemoteDescriptionType(
    JNIEnv* env, jobject thiz, jint pc_id) {
    char* type = ldc_get_remote_description_type(pc_id);
    jstring result = type ? env->NewStringUTF(type) : nullptr;
    if (type) ldc_free(type);
    return result;
}

JNIEXPORT jint JNICALL
Java_com_example_flutter_1libdatachannel_FlutterLibdatachannelPlugin_nativeAddTrack(
    JNIEnv* env, jobject thiz, jint pc_id, jstring init_json) {
    const char* json = init_json ? env->GetStringUTFChars(init_json, nullptr) : nullptr;
    int result = ldc_add_track(pc_id, json);
    if (json) env->ReleaseStringUTFChars(init_json, json);
    return result;
}

JNIEXPORT void JNICALL
Java_com_example_flutter_1libdatachannel_FlutterLibdatachannelPlugin_nativeDeleteTrack(
    JNIEnv* env, jobject thiz, jint tr_id) {
    ldc_delete_track(tr_id);
}

JNIEXPORT jint JNICALL
Java_com_example_flutter_1libdatachannel_FlutterLibdatachannelPlugin_nativeSendTrackMessage(
    JNIEnv* env, jobject thiz, jint tr_id, jbyteArray data) {
    jsize size = env->GetArrayLength(data);
    jbyte* bytes = env->GetByteArrayElements(data, nullptr);
    int result = ldc_send_track_message(tr_id, reinterpret_cast<const uint8_t*>(bytes), size);
    env->ReleaseByteArrayElements(data, bytes, JNI_ABORT);
    return result;
}

JNIEXPORT jint JNICALL
Java_com_example_flutter_1libdatachannel_FlutterLibdatachannelPlugin_nativeSetH264Packetizer(
    JNIEnv* env, jobject thiz, jint tr_id, jstring init_json) {
    const char* json = init_json ? env->GetStringUTFChars(init_json, nullptr) : nullptr;
    int result = ldc_set_h264_packetizer(tr_id, json);
    if (json) env->ReleaseStringUTFChars(init_json, json);
    return result;
}

JNIEXPORT jint JNICALL
Java_com_example_flutter_1libdatachannel_FlutterLibdatachannelPlugin_nativeSetOpusPacketizer(
    JNIEnv* env, jobject thiz, jint tr_id, jstring init_json) {
    const char* json = init_json ? env->GetStringUTFChars(init_json, nullptr) : nullptr;
    int result = ldc_set_opus_packetizer(tr_id, json);
    if (json) env->ReleaseStringUTFChars(init_json, json);
    return result;
}

JNIEXPORT jint JNICALL
Java_com_example_flutter_1libdatachannel_FlutterLibdatachannelPlugin_nativeChainRtcpReceivingSession(
    JNIEnv* env, jobject thiz, jint tr_id) {
    return ldc_chain_rtcp_receiving_session(tr_id);
}

JNIEXPORT jint JNICALL
Java_com_example_flutter_1libdatachannel_FlutterLibdatachannelPlugin_nativeChainRtcpSrReporter(
    JNIEnv* env, jobject thiz, jint tr_id) {
    return ldc_chain_rtcp_sr_reporter(tr_id);
}

} // extern "C"
