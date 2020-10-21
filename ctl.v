/*
 * generate control signals for 65C02 core.
 *
 * This module is organized around a 512x36 bit memory. Half of the
 * memory is used for instruction decoding. The opcode is used as the
 * address (with top bit set to 0). The output is a control word that
 * controls both address and ALU logic, as well as the register file
 * addressing, and flag updates. The sequencer has no conditional 
 * branches and no internal register file. It simply follows a fixed
 * sequence of micro-instructions. Each word contains the address of the next.
 *
 * The other half of the memory is used as a sequencer for multi-cycle
 * instructions. 
 * 
 * Most instructions that operate on memory are divided into two
 * phases. The first phase determines the effective memory address, the
 * second (and final) phase performs the operation.
 *
 * In order to save space, the ROM has a separate area for the 2nd
 * phase, called the 'finishing code'. The first cycle of the control
 * word optionally contains the address of the 'finisher', stored in
 * 5 bit register 'finish'. After the memory has been addressed, the 
 * controller jumps to the finish code to do the operations. This allows
 * for a compact representation.
 *
 * So, for example, the code for LDA ZP points to a finisher that loads ALU
 * into A register. The code for LDX ZP points to a finisher that loads X 
 * register instead. Both instructions then follow the same sequence to read
 * zeropage, and then the respective finisher is called.
 *
 * In the last cycle of an instruction, we no longer need the next location,
 * so the 8 address bits are used to select how the processor status flags
 * are updated.
 *
 * (C) Arlet Ottens <arlet@c-scape.nl> 
 */

module ctl(
    input clk,
    input reset,
    output sync,
    input cond,
    input [7:0] DB,
    output reg WE,
    output [7:0] flags,
    output [6:0] alu_op,
    output [6:0] dp_op,
    output [1:0] do_op,
    output reg [11:0] ab_op );

wire [2:0] adder;
wire [1:0] shift;
wire [1:0] ci;
wire [3:0] src;
wire [2:0] dst;

assign flags = control[7:0];
assign alu_op = { ci, shift, adder };
assign dp_op  = control[21:15];

reg [35:0] microcode[511:0];
reg [35:0] control;

/* 
 * operation for DO (data out)
 */
assign do_op = control[30:29];

/*
 * sync indicates when new instruction is decoded
 */
assign sync = (control[23:22] == 2'b00);

initial 
    $readmemb( "microcode.hex", microcode, 0 );

reg [8:0] pc;
reg [4:0] finish;   // finishing code

/*
 * The microcontrol 'program counter'.
 * 
 * The bits in control[23:22] tell what to do:
 * 
 * when 00 -> decode next instruction, form address in bottom 256 words.
 * when 01 -> jump to next microcode instruction in area 9'h100-9'h17F 
 * when 10 -> jump to finishing code in area 9'h180-9'h19F.
 * when 11 -> jump to next, but also save pointer to finishing code
 */
always @(*) 
    if( reset )
        pc = 9'h180;
    else casez( control[23:22] )
        2'b00:          pc = {1'b0, DB};            // look up next instruction at 000
        2'b?1:          pc = {1'b1, control[7:0]};  // microcode at @100
        2'b10:          pc = {4'b1010, finish };    // finish code at @140
    endcase

/*
 * bit 27 contains WE signal for next cycle
 */
always @(posedge clk)
    WE <= control[28];

/*
 * load next control word from ROM
 */
always @(posedge clk)
    control <= microcode[pc];

/*
 * if bit 23 is set, the ALU is not needed in this cycle
 * so the same bits are used to store location of finisher code
 */
always @(posedge clk)
    if( control[23] )
        finish <= control[14:10];

/*
 * control bits for ALU
 */
assign shift = control[14:13];
assign adder = control[12:10];
assign ci    = control[9:8];

/*
 * The ABL/ABH modules need 12 bits of control signals, but only in a limited
 * number of total options.
 *
 * In order to compress those in the control word, the code below expands 
 * the 4 control bits into 12, optionally taking into account the output
 * of the conditional branches, and the branch direction (DB[7])
 */

always @(*)
    case( control[27:24] )    //              IPHF_AHB_ABL_CI
        4'b0000:                ab_op = 12'bxx10_100_0010_1;     // AB + 1    
        4'b0001:                ab_op = 12'b1110_000_0111_0;     // {00, DB+REG}    
        4'b0010:                ab_op = 12'bxx00_110_1100_0;     // PC         
        4'b0011:                ab_op = 12'b1110_111_1011_0;     // {DB, AHL+REG}, store PC
        4'b0100:                ab_op = 12'b0100_010_0011_0;     // {01, SP}     
        4'b0101:                ab_op = 12'bxx10_100_0010_0;     // AB + 0        
        4'b0110:                ab_op = 12'b0010_111_1011_0;     // {DB, AHL+REG}, keep PC
        4'b0111:                ab_op = 12'b0110_010_0011_1;     // {01, SP+1}
        4'b1000: if( cond )                                      // branch if true 
                    if( DB[7] ) ab_op = 12'bxx10_101_0110_1;     // {AB-1, AB} + DB + 1
                    else        ab_op = 12'bxx10_100_0110_1;     // {AB+0, AB} + DB + 1
                 else           ab_op = 12'bxx10_100_0010_1;     // AB + 1    
        4'b1001: if( !cond )                                     // branch if false
                    if( DB[7] ) ab_op = 12'bxx10_101_0110_1;     // {AB-1, AB} + DB + 1
                    else        ab_op = 12'bxx10_100_0110_1;     // {AB+0, AB} + DB + 1
                 else           ab_op = 12'bxx10_100_0010_1;     // AB + 1    
        4'b1010:                ab_op = 12'b0000_010_0011_0;     // {01, SP}, keep PC
        4'b1011:                ab_op = 12'b1110_010_0011_0;     // {01, SP}, store PC+1
        4'b1100:                ab_op = 12'b0001_000_0011_0;     // {FF, REG}
        4'b1101: if( DB[7] )    ab_op = 12'bxx10_101_0110_1;     // {AB-1, AB} + DB + 1
                 else           ab_op = 12'bxx10_100_0110_1;     // {AB+0, AB} + DB + 1
        default:                ab_op = 12'bxxxx_xxx_xxxx_x;
    endcase

endmodule
