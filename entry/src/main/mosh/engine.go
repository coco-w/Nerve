//go:build js && wasm

package main

import (
	"encoding/base64"
	"strconv"
	"syscall/js"

	mosh "nerve/mosh/internal/protocol"
)

const (
	maxDatagram = 2048
	// 网络中断时限制待发送的键盘输入，一次只发送有界的状态差量。
	maxInput         = 64 * 1024
	maxInputPerState = 4 * 1024
)

type engine struct {
	transport     *mosh.Transport
	input         []byte
	inFlight      int
	columns, rows int32
	resizePending bool
	closing       bool
}

func main() {
	connect := js.FuncOf(open)
	js.Global().Set("nerveMoshEngine", connect)
	select {}
}

func open(_ js.Value, args []js.Value) any {
	key, err := base64.RawStdEncoding.Strict().DecodeString(args[0].String())
	if err != nil || len(key) != 16 {
		return nil
	}
	cipher, err := mosh.NewOCB(key)
	clear(key)
	if err != nil {
		return nil
	}
	session := engine{transport: mosh.NewTransport(cipher, false)}
	session.transport.ForceNextSend()
	return map[string]any{
		"input":    js.FuncOf(session.addInput),
		"resize":   js.FuncOf(session.resize),
		"tick":     js.FuncOf(session.tick),
		"receive":  js.FuncOf(session.receive),
		"probe":    js.FuncOf(session.probe),
		"shutdown": js.FuncOf(session.shutdown),
	}
}

func (s *engine) addInput(_ js.Value, args []js.Value) any {
	data := args[0]
	length := data.Get("byteLength").Int()
	if length < 1 || length > maxInput-len(s.input)-s.inFlight {
		return false
	}
	start := len(s.input)
	s.input = append(s.input, make([]byte, length)...)
	js.CopyBytesToGo(s.input[start:], data)
	return true
}

func (s *engine) resize(_ js.Value, args []js.Value) any {
	s.columns, s.rows = int32(args[0].Int()), int32(args[1].Int())
	s.resizePending = true
	return nil
}

func (s *engine) probe(_ js.Value, _ []js.Value) any {
	s.transport.ForceNextSend()
	return nil
}

func (s *engine) shutdown(_ js.Value, _ []js.Value) any {
	s.closing = true
	clear(s.input)
	s.input = nil
	s.transport.BeginShutdown()
	return nil
}

func (s *engine) tick(_ js.Value, _ []js.Value) any {
	// 有且只有一个待确认状态。切网后继续重发该状态，新输入等确认后再发送，避免重复执行。
	if s.transport.ReadyForInput() {
		s.inFlight = 0
		actions := make([]mosh.UserInstruction, 0, 2)
		if s.resizePending {
			actions = append(actions, mosh.UserInstruction{Width: s.columns, Height: s.rows})
			s.resizePending = false
		}
		if len(s.input) > 0 {
			s.inFlight = min(len(s.input), maxInputPerState)
			actions = append(actions, mosh.UserInstruction{Keys: s.input[:s.inFlight]})
		}
		if len(actions) > 0 {
			s.transport.SetPending(mosh.MarshalUserMessage(actions))
			s.input = s.input[s.inFlight:]
		}
	}
	datagrams := s.transport.Tick()
	if len(datagrams) == 0 {
		return nil
	}
	result := make([]any, 0, len(datagrams))
	for _, datagram := range datagrams {
		result = append(result, jsBytes(datagram))
	}
	return result
}

func (s *engine) receive(_ js.Value, args []js.Value) any {
	data := args[0]
	length := data.Get("byteLength").Int()
	if length < 24 || length > maxDatagram {
		return nil
	}
	packet := make([]byte, length)
	js.CopyBytesToGo(packet, data)
	t := s.transport
	lastPacket, lastState := t.LastRecv(), t.LastRecvNewNum()
	diff := t.Recv(packet)
	if t.LastRecv() == lastPacket {
		return nil
	}
	if s.closing && t.AckedByRemote() == ^uint64(0) {
		return map[string]any{"closed": true}
	}
	newState := t.LastRecvNewNum()
	if newState == lastState {
		return true
	}
	instructions, err := mosh.UnmarshalHostMessage(diff)
	if err != nil {
		return nil
	}
	// 将已认证的屏幕状态交给 xterm。序号以字符串传递，保留完整的 uint64 精度。
	var columns, rows int32
	var screen []byte
	for _, instruction := range instructions {
		screen = append(screen, instruction.Hoststring...)
		if instruction.Width >= 2 && instruction.Width <= 500 && instruction.Height >= 2 && instruction.Height <= 500 {
			columns, rows = instruction.Width, instruction.Height
		}
	}
	return map[string]any{
		"from":          strconv.FormatUint(t.LastRecvOldNum(), 10),
		"state":         strconv.FormatUint(newState, 10),
		"discardBefore": strconv.FormatUint(t.ThrowawayNum(), 10),
		"columns":       columns,
		"rows":          rows,
		"screen":        jsBytes(screen),
		"ended":         newState == ^uint64(0),
	}
}

func jsBytes(data []byte) js.Value {
	out := js.Global().Get("Uint8Array").New(len(data))
	js.CopyBytesToJS(out, data)
	return out
}
