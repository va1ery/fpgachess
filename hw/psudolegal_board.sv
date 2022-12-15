
module psudolegal_board(
  input logic clk,

  input logic        in_pos_valid = 0,
  input logic [3:0]  in_pos_data = 0,
  input logic        in_pos_eop = 0,
  input logic        in_wtp = 0,
  input logic [3:0]  in_castle,
  input logic [2:0]  in_ep,


  // moves ouput in 20-bit UCI format: {promote, piece, from_rf, takes, to_rf}
  //  uci_move_promote 00   {0: no promotion, or queen, 1: bishop, 2: rook, 3: night}
  //  uci_move_piece   000  {none, king, queen, rook, bishop, knight, pawn}
  //  uci_move_from_r  000  rank 0-7
  //  uci_move_from_f  000  file 0-7
  //  uci_move_takes   000  {none, king, queen, rook, bishop, knight, pawn}
  //  uci_move_to_r    000  rank 0-7
  //  uci_move_to_f    000  file 0-7
  input logic       start,
  output reg        o_uci_valid = 0,
  output reg [19:0] o_uci_data = 0,
  output reg        o_uci_sop = 0,
  output reg        o_uci_eop = 0
  );


  // pack and register uci_move output
  wire [1:0] uci_move_promote;
  wire [2:0] uci_move_piece;
  wire [2:0] uci_move_from_r;
  wire [2:0] uci_move_from_f;
  wire [2:0] uci_move_takes;
  wire [2:0] uci_move_to_r;
  wire [2:0] uci_move_to_f;
  wire [19:0] o_uci_data_w;
  assign o_uci_data_w = {uci_move_promote, uci_move_piece, uci_move_from_f, uci_move_from_r, uci_move_takes, uci_move_to_f, uci_move_to_r};
  reg r_load_pieces_d = 0;

  // the signal to know if this was the *last* valid move is very long
  // piece stack -> square_from -> board -> square_to -> arbiter
  // and it's impossible to know if the remaining pieces will generate
  // and valid moves. So we emit the generated moves 'one behind', by
  // buffering it until we know there is one more or we've reached the
  // last piece's output moves, in which case we flush with EOP.
  reg [19:0] o_uci_buffer_data = 0;
  reg        o_uci_buffer_valid = 0;
  reg        o_uci_buffer_sop = 0;
  reg done_sop = 0;

  wire       o_uci_data_valid = stack_interconnect_to_play_o[9] & ~square_done;
  wire last_piece_is_done = !stack_interconnect_to_play_o[10+9] & square_done;
  always_ff @(posedge clk) begin

    // clock generated data into buffer
    if (o_uci_data_valid) begin
      o_uci_buffer_data  <= o_uci_data_w;
      o_uci_buffer_sop <= o_uci_data_valid & !done_sop;
    end
    if (o_uci_data_valid || last_piece_is_done) begin
      o_uci_buffer_valid <= o_uci_data_valid;
      done_sop <= (done_sop | o_uci_data_valid) & !last_piece_is_done;
    end

    // in the cycle after o_uci_data_valid, a square_done signal
    // indicates the buffered move was the last for this piece, and if the
    // piece stack was also the last item, buffered item is last move.
    o_uci_data <= o_uci_buffer_data;
    o_uci_sop <= o_uci_buffer_sop;
    o_uci_valid <= o_uci_buffer_valid && (o_uci_data_valid || last_piece_is_done);
    o_uci_eop <= last_piece_is_done;

    r_load_pieces_d <= load_pieces;
  end

  // track the current rank/file from incoming serial form
  wire [5:0] in_pos_rf;
  movegen_rankfile movegen_rankfile (
    .clk(clk),
    .in_pos_valid( in_pos_valid ),
    .in_pos_sop(in_pos_sop),
//  .in_pos_data(in_pos_data),
    .out_rankfile(in_pos_rf)
  );

  // Instantiate the piece stack, of 2x16-items, and piece iterator 1x16 items.
  // Two stacks, one for white one for black, hold {full,piece,rank,file} in any order.
  // pushing occurs from the in_pos serial load bus when there is a piece of the
  // correct colour {piece_w, piece_b}, no change occurs on empty squares.
  // Each slot in the stack has a presence bit 'full' and a load path to the entry below.
  // When a push occurs, all populated slots shift downards.
  //
  // Both piece stacks can parallel load (depending on in_wtp) into the move-stack,
  // which shifts the contents up one-by-one as moves are generated. Loading into
  // the move_stack does not affect the contents of the white/black stacks.
  //
  //                      white   black         wtp         move_stack
  //
  //     serial in_pos ------+-----+             |  shift_piece--\ /---> uci_move_from_{r,f}
  //           in_pos_w----\ v     v /--in_pos_b |  load_pieces  | |---> uci_move_piece
  //                      [item]-[item]         _|_       +----[item]--> is_last_piece
  //                        |      +-----------|mux|------|-----/| |
  //                        +------|-----------|___|      |      | |
  //                      [item] [item]         _|_       +----[item]
  //                        |      +-----------|mux|------|-----/| |
  //                        +------|-----------|___|      |      | |
  //                      [item] [item]         _|_       +----[item]
  //                        |      +-----------|mux|------|-----/| |
  //                        +------|-----------|___|      |      | |
  //                      [item] [item]          |        +----[item]
  //
  // These stacks let us iterate the next piece to move quickly, without long
  // combinatorial paths through the 64 board squares.
  // they are built with registers rather than block rams for the unusual
  // load paths, and because we will need to push/pop the state
  // when we support board make/unmake move
  wire load_pieces;
  wire next_piece;
  wire in_pos_black = in_pos_valid && in_pos_data[3] == 1'b0 && |in_pos_data[2:0];
  wire in_pos_white = in_pos_valid && in_pos_data[3] == 1'b1 && |in_pos_data[2:0];
  wire [17*10-1:0] stack_interconnect_white;
  wire [17*10-1:0] stack_interconnect_black; // {occupied(1), pos_data(3), in_pos_rf(6)}
  wire [16*10-1:0] stack_interconnect_to_play;
  wire [16*10-1:0] stack_interconnect_to_play_o;
  assign stack_interconnect_black[9:0] = { 1'b1, in_pos_data[2:0], in_pos_rf};
  assign stack_interconnect_white[9:0] = { 1'b1, in_pos_data[2:0], in_pos_rf};
  assign stack_interconnect_to_play = load_pieces ? (in_wtp ? stack_interconnect_white[10 +: 16*10] : stack_interconnect_black[10 +: 16*10]) : {10'b0, stack_interconnect_to_play_o[10 +: 15*10]};

  assign load_pieces = start;
  genvar i;
  generate
    for (i=0; i<16; i=i+1)
    begin: item
      movegen_piece_stack #(.POSITION(i)) movegen_piece_white (
        .clk(clk),
        .clear(in_pos_valid & in_pos_sop),
        .in_data(stack_interconnect_white[i*10 +: 10]),
        .out_data(stack_interconnect_white[(i+1)*10 +: 10]),
        .load(in_pos_white & stack_interconnect_white[i*10+9])
        );

      movegen_piece_stack #(.POSITION(i)) movegen_piece_black (
        .clk(clk),
        .clear(in_pos_valid & in_pos_sop),
        .in_data(stack_interconnect_black[i*10 +: 10]),
        .out_data(stack_interconnect_black[(i+1)*10 +: 10]),
        .load(in_pos_black & stack_interconnect_black[i*10+9])
        );

      movegen_piece_stack #(.POSITION(i)) movegen_move_stack (
        .clk(clk),
        .clear(1'b0),
        .in_data(stack_interconnect_to_play[i*10 +: 10]),
        .out_data(stack_interconnect_to_play_o[i*10 +: 10]),
        .load(load_pieces | next_piece)
      );
    end
  endgenerate
  assign uci_move_from_f = stack_interconnect_to_play_o[0 +: 3];
  assign uci_move_from_r = stack_interconnect_to_play_o[3 +: 3];
  assign uci_move_piece = stack_interconnect_to_play_o[6 +: 3];

  // we jump to the next piece if there are no more destinations
  // for this piece
  assign next_piece = !(|square_to_arb);
  //always @(posedge clk) begin
  //  o_uci_data <= o_uci_data_w;
  //end


  // instantiate the square modules.
  // in_pos_data is a serial load that shifts through each square in turn,
  // so no routing logic/muxes required
  //
  // emit_move signals a square to output valid moves the piece it holds can make.
  // depending on the piece, the piece and colour (white/black) will determine
  // which of the outputs to other squares become hot. The various interconnects
  // pass the signal to the neighbouring squares in each direction on the input lines.
  // Empty squares emit incoming moves as a valid destination by setting their square_to bit.
  // Squares occupied by self (wtp) will block and not emit. opponent squares will emit.
  // slider signals will be blocked by occupied pieces otherwise passed
  // combinatorially to the next square (worst case ripple 8).
  //
  // square_from signals this occupied square to outputing its moves
  // any square with an incoming ray outputs its target_square signal.
  //
  // ie. emit_move -> o_{piece}{dir} signal -> i_{piece}{dir} signal -> target_square
  //
  // squares do not output their piece, this is done by memories clocked from
  // the serial load ports in paralell to the serial load.
  //
  // All 64 target_square bits are fed into an abritrator to iterate the psudo-valid
  // moves that can be made from the selected piece (perhaps none).
  //
  wire [63:0] square_from;   // one-hot, only 1sq holds token at once
  wire [63:0] square_to;     // multi-hot, all destination squares
  wire [63:0] square_to_arb; // one-hot after masking and HTP logic (see below)

  // convert the current cell uci_move_from coordinates from piece_stack to a
  // one-hot signal routed to the board square
  onehot_from_bin #(.WIDTH(64)) onehot_from_bin(
    .in({uci_move_from_r, uci_move_from_f}),
    .out(square_from)
  );

  // serial pos interconnect
  wire [(65*4)-1:0]pos_interconnect; // 64 squares plus unused final square output
  assign pos_interconnect[3:0] = in_pos_data;

  // board move interconnect, each following the name of the driving pins
  wire [9*8-1:0] w_pn, w_ps;

  // for knight wiring center 8x8 board within a 12x12, ie. with 2 padding all round
  wire [12*12-1:0] w_nnne, w_nnnw, w_nsse, w_nssw, w_neen, w_nees, w_nwwn, w_nwws;

  genvar r,f;
  generate
    for (r=0; r<8; r=r+1)
    begin: rank // rows
      for (f=0; f<8; f=f+1)
      begin: file // columns
        // knight rank, knight file, on the 12x12 board
        // nr = r + 2;
        // nf = f + 2;

        movegen_square #(.RANK(r+1), .FILE(f+1)) movegen_square (
          .clk(clk),
          .in_pos_valid(in_pos_valid),
          .in_pos_data( pos_interconnect[(r*8+(7-f)+0)*4 +: 4]),
          .out_pos_data(pos_interconnect[(r*8+(7-f)+1)*4 +: 4]),

          // trigger for this square to emit, and signalling
          // a valid destination
          .emit_move( square_from[r*8+f] ),
          .target_square( square_to[r*8+f]),

          // interconnect signals between squares

          // pawn moves signals are not shared with king because of
          // initial double moves, ep logic, and diagonals being
          //  valid only if taking.
          // from      to
          .o_pn(w_pn[(r+1)*8 + f]),  .i_ps(w_pn[r*8 + f]),
          .o_ps(w_ps[r*8 + f]),      .i_pn(w_ps[(r+1)*8 + f]),
          .o_pne(),   .i_psw(),
          .o_pnw(),   .i_pse(),
          .o_pse(),   .i_pnw(),
          .o_psw(),   .i_pne(),
          // initial double pawn moves also use pn/ps with logic in
          // the board for files 3 and 6 to forward for an extra square.
          // going north:
          //  file 2 sends o_pn, file 3 recieves i_ps,
          //  if unoccupied, file 3 sends o_pn, file 4 recieves i_ps
          // going south,
          //  file 7 send o_ps, file 6 recieves i_pn,
          //  if unoccupied, file 6 sends o_ps, file 5 recieves i_pn

          // a sqaure recieving the pawn diagonal move signals emits if
          // it is occupied and can be taken, OR is unoccupied but the
          // ep flags indicate a pawn double move took place over our
          // square.

          // king moves, clockwise from N
          .o_kn(),    .i_ks(),
          .o_kne(),   .i_ksw(),
          .o_ke(),    .i_kw(),
          .o_kse(),   .i_knw(),
          .o_ks(),    .i_kn(),
          .o_ksw(),   .i_kne(),
          .o_kw(),    .i_ke(),
          .o_knw(),   .i_kse(),

          // slide out rays (used by queen, rook, bishop), clockwise from N
          .o_sn(),    .i_ss(),
          .o_sne(),   .i_ssw(),
          .o_se(),    .i_sw(),
          .o_sse(),   .i_snw(),
          .o_ss(),    .i_sn(),
          .o_ssw(),   .i_sne(),
          .o_sw(),    .i_se(),
          .o_snw(),   .i_sse(),

          // knight L-moves, these skip the intermediate squares
          // r+2, f+2 translates us to the square on the 12x12 knight board
          .o_nnne(w_nnne[(r+2+2)*12 + (f+2+1)]),  .i_nssw(w_nnne[(r+2)*12 + (f+2)]),
          .o_nnnw(w_nnnw[(r+2+2)*12 + (f+2-1)]),  .i_nsse(w_nnnw[(r+2)*12 + (f+2)]),
          .o_nsse(w_nsse[(r+2-2)*12 + (f+2+1)]),  .i_nnnw(w_nsse[(r+2)*12 + (f+2)]),
          .o_nssw(w_nssw[(r+2-2)*12 + (f+2-1)]),  .i_nnne(w_nssw[(r+2)*12 + (f+2)]),
          .o_nwwn(w_nwwn[(r+2+1)*12 + (f+2-2)]),  .i_nees(w_nwwn[(r+2)*12 + (f+2)]),
          .o_nwws(w_nwws[(r+2-1)*12 + (f+2-2)]),  .i_neen(w_nwws[(r+2)*12 + (f+2)]),
          .o_neen(w_neen[(r+2+1)*12 + (f+2+2)]),  .i_nwws(w_neen[(r+2)*12 + (f+2)]),
          .o_nees(w_nees[(r+2-1)*12 + (f+2+2)]),  .i_nwwn(w_nees[(r+2)*12 + (f+2)]),

          // 4-bit castelling rights for KQkq are input to all squares,
          // but only used by king squares e1 e8. If the rights are present,
          // and the king's moves are being examined (emit_move), they output
          // the o_castle_e/w signals along the row. Adjacent squares pass
          // the signal if they are *empty*.
          // UCI standard uses the src/dest square of the king to notate
          // castling, ie. e1c1,e1g1,e8c8,e8g8 so we terminate the signal at dest.
          // Rooks need not emit on the castle_e/w lines since they must be in
          // place or the casteling rights would be lost, and there are no
          // intermediate squares between them and the destination square.
          .i_castle_rights(in_castle),
          .o_castle_e(),     .i_castle_w(),
          .o_castle_w(),     .i_castle_e(),

          // white to play
          .wtp(in_wtp)
        );
        // assign square_from[r*8+f] = movegen_square;
      end

      assign w_pn[0 + r] = 0; // no incoming N
      assign w_ps[64 + r] = 0; // no incoming S

    end
  endgenerate

  // zero out unused move-in pins that have no squares feeding them
  // these will get propagated into the squares and minimise the
  // resulting logic.
  genvar nr,nf;
  generate
    for (nr=0; nr<12; nr=nr+1)
    begin: nrank // rows
      for (nf=0; nf<12; nf=nf+1)
      begin: nfile // columns
        if ((nr-2) < 2 || (nf-2) < 1) begin
          assign w_nnne[nr*12 + nf] = 0;
        end
        if ((nr-2) < 2 || (nf-2) > 6) begin
          assign w_nnnw[nr*12 + nf] = 0;
        end
        if ((nr-2) > 5 || (nf-2) < 1) begin
          assign w_nsse[nr*12 + nf] = 0;
        end
        if ((nr-2) > 5 || (nf-2) > 6) begin
          assign w_nssw[nr*12 + nf] = 0;
        end
        if ((nr-2) < 4 || (nf-2) < 1) begin
          assign w_nwwn[nr*12 + nf] = 0;
        end
        if ((nr-2) < 4 || (nf-2) < 1) begin
          assign w_nwws[nr*12 + nf] = 0;
        end
        if ((nr-2) < 4 || (nf-2) < 1) begin
          assign w_neen[nr*12 + nf] = 0;
        end
        if ((nr-2) < 4 || (nf-2) < 1) begin
          assign w_nees[nr*12 + nf] = 0;
        end
      end
    end
  endgenerate


  // all possible destinations of a piece output simultaniously on square_to
  // this request arbiter iterates through them using the usual bitscan
  // technique on carry chains
  // square_to_arb is then a one-hot destination square, and iterates every
  // cycle until the 65th bit, get priority, which is a 'no-more moves' bit
  // to pop to the next piece stack.
  reg [64:0] square_base = 1;
  wire square_done;
  arbiter #(.WIDTH(65)) arbiter_target (
    .base(square_base),
    .req({{1'b1, square_to}}),
    .grant({{square_done, square_to_arb}})
  );
  always @(posedge clk) begin
    if (start || square_done) begin
      square_base <= 1;
    end else if (|square_to_arb) begin
      square_base <= square_to_arb << 1;
    end
  end

  // convert one-hot square_to_arb to a 6-bit square rank/file
  wire [5:0] square_to_rf;
  onehot_to_bin #(.ONEHOT_WIDTH(64) ) oh2b_square_to (.onehot(square_to_arb), .bin(square_to_rf));

  assign uci_move_to_r = square_to_rf[3 +: 3];
  assign uci_move_to_f = square_to_rf[0 +: 3];
  assign uci_move_promote = 0;
  assign uci_move_takes = 0;

  movegen_lookup_output movegen_lookup (
    .clk(clk),
    .in_pos_valid(in_pos_valid),
    .in_pos_data(in_pos_data),
    .in_pos_sop(in_pos_sop),

    .lookup_rankfile({uci_move_to_r, uci_move_to_f}),
    .out_piece()
  );

endmodule
