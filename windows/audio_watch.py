"""读取 Windows 当前的录音设备状态(默认麦克风、已连接的麦克风),用来发现插拔和默认设备切换。

PortAudio 只在初始化时读一次设备列表,之后插上的 USB 麦克风、系统里改的默认设备它都不知道,
所以由 engine 的后台线程定期调用 capture_signature(),变化时重新初始化 PortAudio。
capture_devices() 读出每个麦克风的名称、接入方式和类型,供"自动"选麦克风排优先级。
COM 对象不能跨线程,DeviceWatcher 只在创建它的线程里使用。
"""
import ctypes
import logging
from ctypes import POINTER, Structure, Union, c_int, c_uint, c_ulong, c_ushort, c_void_p
from ctypes.wintypes import DWORD

import comtypes
from comtypes import COMMETHOD, GUID, HRESULT, IUnknown

log = logging.getLogger("audio_watch")

CLSID_MMDeviceEnumerator = GUID("{BCDE0395-E52F-467C-8E3D-C4579291692E}")
E_CAPTURE = 1            # 数据方向:录音
E_RENDER = 0             # 数据方向:播放
E_CONSOLE = 0            # 角色:系统"默认设备"
DEVICE_STATE_ACTIVE = 1

_ole32 = ctypes.windll.ole32
_ole32.CoTaskMemFree.argtypes = [c_void_p]

# 麦克风优先级(数字越小越优先):独立 USB 麦克风 > 耳机上的麦克风 > 电脑自带 > 蓝牙耳机;虚拟设备不自动选
RANK_STANDALONE, RANK_HEADSET, RANK_BUILTIN, RANK_BLUETOOTH, RANK_VIRTUAL = range(5)
RANK_NAMES = ["独立麦克风", "耳机麦克风", "电脑自带", "蓝牙耳机", "虚拟设备"]
FORM_HEADPHONES, FORM_HEADSET, FORM_HANDSET = 3, 5, 6
BLUETOOTH_ENUMS = {"BTHENUM", "BTHHFENUM", "BTHLEDEVICE", "BTHLE"}
VIRTUAL_ENUMS = {"ROOT", "SWD", "SW"}


class PROPERTYKEY(Structure):
    _fields_ = [("fmtid", GUID), ("pid", DWORD)]


class _PVValue(Union):
    _fields_ = [("ulVal", c_ulong), ("pwszVal", ctypes.c_wchar_p), ("ptr", c_void_p)]


class PROPVARIANT(Structure):
    _fields_ = [("vt", c_ushort), ("r1", c_ushort), ("r2", c_ushort), ("r3", c_ushort),
                ("v", _PVValue), ("pad", c_void_p)]


class IPropertyStore(IUnknown):
    _iid_ = GUID("{886d8eeb-8cf2-4446-8d02-cdba1dbdcf99}")
    _methods_ = [
        COMMETHOD([], HRESULT, "GetCount", (["out"], POINTER(DWORD), "c")),
        COMMETHOD([], HRESULT, "GetAt", (["in"], DWORD, "i"), (["out"], POINTER(PROPERTYKEY), "k")),
        COMMETHOD([], HRESULT, "GetValue", (["in"], POINTER(PROPERTYKEY), "key"),
                  (["out"], POINTER(PROPVARIANT), "pv")),
    ]


PKEY_FRIENDLY_NAME = PROPERTYKEY(GUID("{a45c254e-df1c-4efd-8020-67d146a850e0}"), 14)
PKEY_ENUMERATOR = PROPERTYKEY(GUID("{a45c254e-df1c-4efd-8020-67d146a850e0}"), 24)   # 接入方式:USB / BTHENUM / ROOT…
PKEY_FORM_FACTOR = PROPERTYKEY(GUID("{1da5d803-d492-4edd-8c23-e0c0ffee7f0e}"), 0)    # 类型:麦克风 4 / 耳机 5…


def _prop(store, key):
    pv = store.GetValue(ctypes.byref(key))
    try:
        if pv.vt == 31:   # VT_LPWSTR
            return pv.v.pwszVal or ""
        if pv.vt == 19:   # VT_UI4
            return pv.v.ulVal
        return None
    finally:
        _ole32.PropVariantClear(ctypes.byref(pv))


def rank_of(enumerator, form):
    e = (enumerator or "").upper()
    if e in VIRTUAL_ENUMS:
        return RANK_VIRTUAL
    if e in BLUETOOTH_ENUMS:
        return RANK_BLUETOOTH
    headset = form in (FORM_HEADPHONES, FORM_HEADSET, FORM_HANDSET)
    if e == "USB":
        return RANK_HEADSET if headset else RANK_STANDALONE
    return RANK_HEADSET if headset else RANK_BUILTIN


class IMMDevice(IUnknown):
    _iid_ = GUID("{D666063F-1587-4E43-81F1-B948E807363F}")
    _methods_ = [
        COMMETHOD([], HRESULT, "Activate", (["in"], POINTER(GUID), "iid"), (["in"], DWORD, "ctx"),
                  (["in"], c_void_p, "params"), (["out"], POINTER(c_void_p), "ppInterface")),
        COMMETHOD([], HRESULT, "OpenPropertyStore", (["in"], DWORD, "access"),
                  (["out"], POINTER(c_void_p), "ppProperties")),
        # 字符串由系统分配,需要自己 CoTaskMemFree,所以按裸指针声明
        COMMETHOD([], HRESULT, "GetId", (["out"], POINTER(c_void_p), "ppstrId")),
        COMMETHOD([], HRESULT, "GetState", (["out"], POINTER(DWORD), "pdwState")),
    ]


class IMMDeviceCollection(IUnknown):
    _iid_ = GUID("{0BD7A1BE-7A1A-44DB-8397-CC5392387B5E}")
    _methods_ = [
        COMMETHOD([], HRESULT, "GetCount", (["out"], POINTER(c_uint), "pcDevices")),
        COMMETHOD([], HRESULT, "Item", (["in"], c_uint, "nDevice"),
                  (["out"], POINTER(POINTER(IMMDevice)), "ppDevice")),
    ]


class IMMDeviceEnumerator(IUnknown):
    _iid_ = GUID("{A95664D2-9614-4F35-A746-DE8DB63617E6}")
    _methods_ = [
        COMMETHOD([], HRESULT, "EnumAudioEndpoints", (["in"], c_int, "dataFlow"),
                  (["in"], DWORD, "stateMask"),
                  (["out"], POINTER(POINTER(IMMDeviceCollection)), "ppDevices")),
        COMMETHOD([], HRESULT, "GetDefaultAudioEndpoint", (["in"], c_int, "dataFlow"),
                  (["in"], c_int, "role"), (["out"], POINTER(POINTER(IMMDevice)), "ppEndpoint")),
    ]


def _device_id(dev):
    ptr = dev.GetId()
    try:
        return ctypes.wstring_at(ptr)
    finally:
        _ole32.CoTaskMemFree(ptr)


class DeviceWatcher:
    def __init__(self):
        comtypes.CoInitialize()
        self._enum = comtypes.CoCreateInstance(
            CLSID_MMDeviceEnumerator, IMMDeviceEnumerator, comtypes.CLSCTX_ALL)

    def capture_signature(self):
        """返回 (默认麦克风 id, 已连接麦克风 id 列表, 默认输出设备 id),任一变化说明需要刷新。
        默认输出设备也要看:提示音走 WASAPI,PortAudio 记住的默认输出要重新初始化才会更新。"""
        try:
            default = _device_id(self._enum.GetDefaultAudioEndpoint(E_CAPTURE, E_CONSOLE))
        except comtypes.COMError:
            default = ""  # 一个麦克风都没有
        coll = self._enum.EnumAudioEndpoints(E_CAPTURE, DEVICE_STATE_ACTIVE)
        ids = sorted(_device_id(coll.Item(i)) for i in range(coll.GetCount()))
        try:
            output = _device_id(self._enum.GetDefaultAudioEndpoint(E_RENDER, E_CONSOLE))
        except comtypes.COMError:
            output = ""
        return default, tuple(ids), output

    def capture_devices(self):
        """已连接的麦克风:[{"name", "rank", "default"}],按优先级排好。"""
        try:
            default = _device_id(self._enum.GetDefaultAudioEndpoint(E_CAPTURE, E_CONSOLE))
        except comtypes.COMError:
            default = ""
        coll = self._enum.EnumAudioEndpoints(E_CAPTURE, DEVICE_STATE_ACTIVE)
        out = []
        for i in range(coll.GetCount()):
            dev = coll.Item(i)
            try:
                store = ctypes.cast(dev.OpenPropertyStore(0), POINTER(IPropertyStore))
                name = _prop(store, PKEY_FRIENDLY_NAME) or ""
                rank = rank_of(_prop(store, PKEY_ENUMERATOR), _prop(store, PKEY_FORM_FACTOR))
            except comtypes.COMError:
                continue
            out.append({"name": name, "rank": rank, "default": _device_id(dev) == default})
        out.sort(key=lambda d: (d["rank"], not d["default"]))
        return out
