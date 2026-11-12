# LAME

MP3 编码使用 LAME 3.100 动态库（LGPL）。来源：https://lame.sourceforge.io/ 。
构建时从本机 Homebrew 的 `lame` 安装复制动态库到应用 Frameworks,不静态链接。
运行时不要求安装 Homebrew,应用随附该库。许可证随应用保存于 Resources/LAME-COPYING.txt。
对应源码：https://sourceforge.net/projects/lame/files/lame/3.100/lame-3.100.tar.gz/download 。
源码中 MP3Encoder 通过公开的 LAME C 接口加载动态库,可替换库后重新构建并签名。
