// The blocks, as React Native components.
//
// One component per kind, each taking the same keys the JSON API returns and
// the web templates render. That is the whole point of the split: the shape of
// a block is described once, on the server, and the two faces disagree about
// nothing except how to draw it.
//
// Reusable in the ordinary sense: a module that wants a heading imports
// TitleBlock rather than styling a Text itself, and a change to how a caption
// looks happens here rather than in every screen.
import React, { useState } from "react";
import {
  ActivityIndicator,
  Dimensions,
  Image,
  ScrollView,
  StyleSheet,
  Text,
  View
} from "react-native";
import { WebView } from "react-native-webview";

export function TitleBlock({ block }) {
  if (!block.text) return null;
  return <Text style={styles.title}>{block.text}</Text>;
}

export function TextBlock({ block }) {
  if (!block.text) return null;
  return <Text style={styles.body}>{block.text}</Text>;
}

export function Caption({ children }) {
  if (!children) return null;
  return <Text style={styles.caption}>{children}</Text>;
}

export function ImageBlock({ block }) {
  const source = block.media?.[0];
  if (!source) return <Missing kind="image" />;

  return (
    <View style={styles.figure}>
      <RemoteImage uri={source} />
      <Caption>{block.caption}</Caption>
    </View>
  );
}

// Horizontal paging rather than a carousel library. A ScrollView with snapping
// is what a carousel is, and a dependency here would be a dependency in every
// app this module is installed into.
export function CarouselBlock({ block }) {
  const width = Dimensions.get("window").width - 32;
  const [at, setAt] = useState(0);

  if (!block.media?.length) return <Missing kind="carousel" />;

  return (
    <View style={styles.figure}>
      <ScrollView
        horizontal
        pagingEnabled
        showsHorizontalScrollIndicator={false}
        onMomentumScrollEnd={(event) =>
          setAt(Math.round(event.nativeEvent.contentOffset.x / width))
        }
      >
        {block.media.map((uri) => (
          <RemoteImage key={uri} uri={uri} style={{ width }} />
        ))}
      </ScrollView>

      <View style={styles.dots}>
        {block.media.map((uri, index) => (
          <View key={uri} style={[styles.dot, index === at && styles.dotOn]} />
        ))}
      </View>

      <Caption>{block.caption}</Caption>
    </View>
  );
}

// A WebView rather than a video package.
//
// The shell already carries react-native-webview, and it plays both a file the
// module uploaded and an embed somebody pasted. A native player would mean a
// dependency, and this module would then require a capability an operator has
// to approve before a page could show a video at all.
export function VideoBlock({ block }) {
  const source = block.media?.[0] || block.url;
  if (!source) return <Missing kind="video" />;

  const html = block.media?.length
    ? `<body style="margin:0;background:#000">
         <video controls playsinline style="width:100%;height:100%" src="${source}"></video>
       </body>`
    : null;

  return (
    <View style={styles.figure}>
      <View style={styles.video}>
        <WebView
          source={html ? { html } : { uri: source }}
          allowsFullscreenVideo
          mediaPlaybackRequiresUserAction={false}
          style={styles.fill}
        />
      </View>
      <Caption>{block.caption}</Caption>
    </View>
  );
}

// A kind this build does not know about is a page that still renders.
//
// The block list is the server's, and a phone in somebody's pocket is older
// than the server it talks to. Refusing to draw the rest of the page because
// of one unknown block would be the wrong trade.
function Unknown({ block }) {
  return <Text style={styles.missing}>A {block.kind} block, which this version of the app cannot draw.</Text>;
}

function Missing({ kind }) {
  return <Text style={styles.missing}>A {kind} block with nothing in it yet.</Text>;
}

function RemoteImage({ uri, style }) {
  const [ratio, setRatio] = useState(16 / 9);
  const [loading, setLoading] = useState(true);

  return (
    <View>
      <Image
        source={{ uri }}
        style={[styles.image, { aspectRatio: ratio }, style]}
        resizeMode="cover"
        onLoad={(event) => {
          const { width, height } = event.nativeEvent.source || {};
          if (width && height) setRatio(width / height);
          setLoading(false);
        }}
        onError={() => setLoading(false)}
      />
      {loading ? <ActivityIndicator style={styles.spinner} /> : null}
    </View>
  );
}

export const BLOCKS = {
  title: TitleBlock,
  text: TextBlock,
  image: ImageBlock,
  carousel: CarouselBlock,
  video: VideoBlock
};

export function Block({ block }) {
  const Component = BLOCKS[block.kind] || Unknown;
  return <Component block={block} />;
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  title: { fontSize: 22, fontWeight: "700", marginTop: 18, marginBottom: 6 },
  body: { fontSize: 16, lineHeight: 24, marginBottom: 14 },
  caption: { fontSize: 13, color: "#6b7280", marginTop: 6 },
  figure: { marginBottom: 18 },
  image: { width: "100%", borderRadius: 10, backgroundColor: "#f3f4f6" },
  video: { width: "100%", aspectRatio: 16 / 9, borderRadius: 10, overflow: "hidden", backgroundColor: "#000" },
  spinner: { position: "absolute", alignSelf: "center", top: "45%" },
  dots: { flexDirection: "row", justifyContent: "center", gap: 6, marginTop: 8 },
  dot: { width: 6, height: 6, borderRadius: 3, backgroundColor: "#d1d5db" },
  dotOn: { backgroundColor: "#2563eb" },
  missing: { fontSize: 14, color: "#9ca3af", fontStyle: "italic", marginBottom: 14 }
});
